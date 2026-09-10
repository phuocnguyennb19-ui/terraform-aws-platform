# terraform-aws-platform

The **values** for the AWS platform: one `config.yaml` and one `backend.hcl` per
environment. There is no Terraform code here, no Makefile and no pipeline.

The code — the root composition and every module — lives in
[`terraform-module`](../terraform-module). A deploy clones it at a pinned tag, copies one
environment's two files into the clone, and runs Terraform from the clone's root.

```
terraform-module          root (*.tf) + modules/ — the code, released by tag
        ▲
        │  git clone --branch <tag>; config.yaml + backend.hcl copied in
        │
terraform-aws-platform    this repo — values and state locations, per environment
```

Current release: **`terraform-module` `v1.2.1`**.

---

## Layout

```
terraform-aws-platform/
├── README.md
└── environments/
    ├── dev/
    │   ├── config.yaml     every value that makes dev different
    │   └── backend.hcl     which state this config writes
    ├── staging/
    └── prod/
```

An environment is these two files and nothing more. All three environments run the same
root, so they cannot drift apart structurally: staging is a real rehearsal for prod because
the only thing that differs is values.

---

## Deploying

Terraform must run from the clone's root — the root reads the config as
`file("${path.cwd}/${var.config_file}")`, relative to the directory Terraform runs from.

```bash
ENV=dev          # dev | staging | prod
TAG=v1.2.1       # the terraform-module release this environment runs

git clone --quiet --depth 1 --branch "$TAG" \
  https://github.com/phuocnguyennb19-ui/terraform-module.git tf
cp "environments/$ENV/config.yaml" tf/config.yaml
cp "environments/$ENV/backend.hcl" tf/backend.hcl

cd tf
terraform init -reconfigure -input=false -backend-config=backend.hcl
terraform plan -input=false -var config_file=config.yaml -out=tfplan   # read it
terraform apply -input=false tfplan                                     # applies what was read
```

- **Apply the saved plan, never a bare `terraform apply`.** A bare apply plans again, so what
  gets applied is not what anyone read.
- **The config and the backend always travel together.** Copying `dev/config.yaml` with
  `prod/backend.hcl` plans dev values against prod state.
- **Pin a tag, never a branch.** A new `terraform-module` release reaches an environment only
  when its deploy is pointed at the new tag.
- **First enable of ACM + ALB needs two passes.** The certificate must reach `ISSUED` before
  the HTTPS listener can use it; re-run plan and apply once DNS validation completes.

`terraform output` in the clone shows what was built — `enabled_modules`, `vpc_id`,
`alb_dns_name`, `rds_endpoint`, `ecr_repository_urls` and the rest.

---

## Writing a config

```yaml
global:
  project: platform
  environment: dev          # prod switches on the hardening floor below
  region: ap-southeast-1

vpc:
  enabled: true
  cidr: "10.10.0.0/16"

rds:
  enabled: true
  instance_class: db.t4g.medium
```

- **A module is built only when its block says `enabled: true`.** A block absent from the
  file is not built; there is no `enabled: false` to write.
- **Any key left out takes the module's default.** Write only what is a decision.
- **The environment is `global.environment`, not a flag.** It names the environment in the
  file that describes it, so a config cannot be applied as a different environment by
  accident.
- **An application stack** disables the shared modules and names what it uses under
  `existing:` — by name and tag, never by raw ID.

Blocks the root understands: `kms`, `vpc`, `security_groups`, `iam`, `cloudwatch`, `ecr`,
`route53`, `acm`, `alb`, `ecs_cluster`, `ecs_services`, `eks`, `ec2`, `rds`, `elasticache`,
`lambda`, `existing`. Every key is read in `terraform-module`'s `locals.tf` and `main.tf` as
`try(local.config.<block>.<key>, <default>)` — that is the reference.

### What the environments differ in

| | dev | staging | prod |
|---|---|---|---|
| CIDR | `10.10.0.0/16` | `10.20.0.0/16` | `10.30.0.0/16` |
| AZs | 2 | 3 | 3, pinned explicitly |
| NAT gateways | 1 (shared) | one per AZ | one per AZ (forced) |
| RDS | single-AZ, `t4g.medium` | multi-AZ, `t4g.large` | multi-AZ, `r6g.xlarge` |
| Backups | 3 days | 7 days | 30 days (floor) |
| Deletion protection | off | off | on (forced) |
| EKS API endpoint | public, CIDR-restricted | public, CIDR-restricted | private (forced) |
| EKS capacity | spot only | on-demand + spot | on-demand floor + spot |
| ElastiCache | — | 2 nodes | 3 nodes |
| Log retention | 7 days | 30 days | 365 days (floor 90) |
| TLS | none (HTTP) | ACM | ACM |

### Production hardening floor

When `global.environment` is `prod`, the root forces these regardless of what the config
says. Raising a value above the floor works; going below it is not expressible.

| Forced in prod | Protects against |
|---|---|
| One NAT gateway per AZ | an AZ failure removing egress for the whole VPC |
| RDS multi-AZ, deletion protection, final snapshot | an AZ failure or a mistargeted destroy reaching the data |
| RDS backups ≥ 30 days | corruption discovered in week three being unrecoverable |
| ALB deletion protection | the same, for the entry point |
| EKS API endpoint private | the control plane being one credential leak from the internet |
| Flow logs on, log retention ≥ 90 days | an investigation with nothing to read |
| ElastiCache ≥ 2 nodes | a cache failure becoming a cold start under load |
| EC2 termination protection, ECS ≥ 2 tasks | an accidental terminate; a deploy being an outage |

---

## State

`backend.hcl` names the bucket, key, region and lock for its environment; the root's
`backend "s3" {}` is empty and takes them at `init`. One environment, one bucket, one key.

**Locking is not optional.** On Terraform 1.5.7 (`terraform-module`'s pinned CLI) it needs a
DynamoDB table with partition key `LockID` (`dynamodb_table` in `backend.hcl`); on ≥ 1.10,
replace that line with `use_lockfile = true`.

The bucket and table must exist before the first `init`. Create them once, out of band:

```bash
BUCKET=my-terraform-state-dev
REGION=ap-southeast-1

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

# Versioning: the only way back from a corrupted or truncated state.
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# Encryption: state holds every resolved value in plaintext.
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region "$REGION"
```

**Treat state and saved plans as sensitive.** Both carry resolved values in plaintext; never
publish a `tfplan` as a build artifact.

---

## Secrets

**No secret belongs in a config file**, and the root gives you nowhere to put one:

| Secret | How it is handled |
|---|---|
| Database master password | Generated and rotated by AWS into Secrets Manager; the RDS module has no password input, so the value never passes through Terraform. |
| Redis AUTH token | Referenced by Secrets Manager ARN (`elasticache.auth_token_secret_arn`). |
| TLS private keys | Issued and renewed by ACM; never leave AWS. |
| AWS credentials | An assumed role (`global.assume_role_arn`) or OIDC in CI — never a value here. |
| Container secrets | By ARN under `secrets:`, fetched by the ECS execution role at task start. |

---

## Known limitations

1. **Not yet planned against a live AWS account.** All three environments plan cleanly
   against a local AWS mock (moto) at `terraform-module` `v1.2.1` — dev 131, staging 166,
   prod 176 resources. First-apply behaviour against real AWS is unverified.
2. **Placeholders to replace before a real deploy:**
   - `backend.hcl` — the `REPLACE-ME` bucket and lock table; `init` fails until they exist.
   - staging / prod `route53.domain_name` — `staging.example.com` / `example.com` with
     `create_zone: false`; the zone lookup fails until it names a real delegated zone.
   - dev / staging `eks.public_api_cidrs` — `203.0.113.0/24` is a documentation range; set
     it to your office or VPN egress range.
3. **No automated checks live here.** There is no pipeline in this repository; whatever runs
   the deploy is where plan review and approval gates belong.
