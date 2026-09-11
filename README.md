# terraform-aws-platform

The developer-facing AWS platform. You describe what your service needs in one
`config.yaml`; the platform turns it into infrastructure.

```
terraform/<env>/config.yaml        you edit this — services, database, cache, DNS
        │  yamldecode → validate → defaults → normalize        terraform/config.tf, validation.tf
        ▼
terraform/main.tf                  composition: which modules, wired how
        │  source = "git::…/terraform-module.git//modules/<name>?ref=v1.3.0"
        ▼
terraform-root-module              generic modules — typed inputs, no YAML
        ▼
AWS
```

These two repositories are the whole system. Module versions are pinned by one `?ref=` on
every `source` in `terraform/main.tf`; CI fails if they differ.

---

## For developers: `config.yaml`

```yaml
environment: dev                  # must match the folder name
account_id: "111122223333"        # quoted: an unquoted ID loses leading zeros
region: ap-southeast-1

dns:                              # optional; required for more than one public service, and in prod
  domain: dev.example.com

services:
  payment:
    image: payment:1.4.2          # <ecr-repo>:<tag>, or a full registry URI; never :latest
    size: medium                  # small | medium | large
    replicas: 2                   # default: 1 in dev, 2 in staging and prod
    public: true                  # true → ALB + https://payment.<dns.domain>
    health_check: /healthz        # default /healthz, on port 8080
    autoscaling: { min: 2, max: 10 }
    env:
      LOG_LEVEL: info
    secrets:                      # references only — never a value
      API_KEY: arn:aws:secretsmanager:ap-southeast-1:111122223333:secret:payment-api-key

database:
  enabled: true
  size: small                     # small | medium | large

cache:
  enabled: false
  size: small

kubernetes:
  enabled: false                  # optional EKS cluster for the platform team
```

Only `environment`, `account_id` and `region` are required. Everything else has a default.

| You write | You get |
|---|---|
| `services.<name>` | An ECS Fargate service `platform-<env>-<name>`, logs, alarms, and an ECR repository named after the image |
| `size` | `small` 0.25 vCPU / 512 MiB · `medium` 0.5 vCPU / 1 GiB · `large` 1 vCPU / 2 GiB |
| `public: true` | A target group on the shared ALB; with `dns.domain`, `https://<name>.<domain>` and a wildcard certificate |
| `database.enabled` | PostgreSQL 16 — `small` db.t4g.medium · `medium` db.t4g.large · `large` db.r6g.xlarge; every service gets `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME` |
| `cache.enabled` | Redis 7 — `small` cache.t4g.small · `medium` cache.t4g.medium · `large` cache.r7g.large; every service gets `REDIS_HOST`, `REDIS_PORT` |
| `secrets` | Injected as environment variables at task start; the execution role is granted exactly those ARNs |

Every service listens on **port 8080**. A mistake fails with a message that names the field:

```
terraform/dev/config.yaml is invalid:

  - Invalid services.payment.size: "xlarge"
    Supported values:
    - small
    - medium
    - large
```

**Secrets.** An `env` name that looks like a credential (`PASSWORD`, `SECRET`, `TOKEN`,
`PRIVATE_KEY`) is rejected — put it under `secrets` as a Secrets Manager or SSM ARN. The RDS
master credentials live in Secrets Manager; `terraform output database_master_secret_arn`
gives the ARN to reference.

---

## What the platform decides per environment

Set in `terraform/config.tf` (`local.environments`), not in `config.yaml`:

| | dev | staging | prod |
|---|---|---|---|
| VPC CIDR / AZs | `10.10.0.0/16`, 2 | `10.20.0.0/16`, 3 | `10.30.0.0/16`, 3 pinned |
| NAT gateways | 1 shared | one per AZ | one per AZ |
| Log / flow-log retention | 7 days | 30 days | 365 days |
| Default replicas | 1 | 2 | 2 (fewer is rejected) |
| RDS | single-AZ, 3-day backups | multi-AZ, 7 days | multi-AZ, 30 days, deletion protection |
| Redis nodes | 1 | 2 | 3 |
| ECS Exec | on | on | off |
| Public traffic | HTTP or HTTPS | HTTP or HTTPS | HTTPS only (`dns.domain` required) |

---

## Running it locally

```bash
cd terraform
terraform init -reconfigure -backend-config=dev/backend.hcl
terraform plan -var environment=dev -out=tfplan
terraform apply tfplan          # applies exactly what was planned
```

Switching environment means `init -reconfigure` against that environment's `backend.hcl` —
the config and the state always travel together. The provider refuses to run when your
credentials are not for `account_id` (`allowed_account_ids`).

---

## CI/CD

`.gitlab-ci.yml` includes the templates in `ci/terraform.gitlab-ci.yml` (`.tf-validate`,
`.tf-plan`, `.tf-apply`); each environment job only sets `TF_ENV`.

```
change terraform/<env>/config.yaml → MR
  validate   fmt · one ?ref= · terraform validate · every config.yaml checked (no AWS needed)
  plan:<env> only for environments whose files changed; saved plan as an artifact
merge → default branch
  apply:<env>  manual; applies that saved plan; staging waits for dev, prod for staging
```

| Variable | Where | Meaning |
|---|---|---|
| `ENVIRONMENT` | **Run pipeline** form | `dev` / `staging` / `prod` runs only that environment; empty runs every environment whose files changed |
| `TF_ROOT`, `TF_VERSION` | `.gitlab-ci.yml` | Terraform directory and CLI version |
| `AWS_PLAN_ROLE_ARN` | CI/CD variable, scoped to each environment | Read-only plan role; not protected — MR pipelines need it |
| `AWS_APPLY_ROLE_ARN` | CI/CD variable, scoped to each environment, **protected** | Deploy role |

Authentication is GitLab OIDC — no AWS keys are stored. Create protected environments
`dev`, `staging`, `prod` with required approvals; the IAM OIDC provider's audience is the
GitLab URL (`CI_SERVER_URL`). The plan artifact holds resolved values in plaintext: one-day
expiry, developer access only.

---

## State

`terraform/<env>/backend.hcl` names the bucket, key, region and lock table; the key contains
the environment, so environments never share state. Terraform 1.5.7 locks through a DynamoDB
table with partition key `LockID`.

Create the bucket and table once per environment, before the first `init`:

```bash
BUCKET=my-terraform-state-dev
REGION=ap-southeast-1

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
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

State and saved plans carry resolved values in plaintext — treat both as sensitive.

---

## Changing the platform

- **A new developer option** → `config.tf` (normalize), `validation.tf` (reject bad values),
  `main.tf` (wire it). Keep `config.yaml` backwards compatible: it is a public API.
- **A capability no module has** → change the module in `terraform-root-module`, release a
  tag, bump every `?ref=` in `main.tf` together.
- **Never** read YAML inside a module, and never put a secret value in `config.yaml`.

---

## Known limitations

1. **`terraform-root-module` `v1.3.0` must be tagged and pushed** before `init` works: it adds
   `ecs-service.enable_load_balancer`, without which a service cannot attach to a target group
   created in the same apply.
2. **Placeholders:** `account_id: "REPLACE-ME"` and `image: api:REPLACE-ME` in every
   `config.yaml` (validate fails until `account_id` is real); the `REPLACE-ME` bucket and lock
   table in every `backend.hcl`; `staging.example.com` / `example.com` must be real delegated
   zones.
3. **Services call each other through their API** — `https://<name>.<dns.domain>`, the same URL
   clients use — so a service another service calls must be `public: true`. There is no
   private service-to-service path (no Service Connect; tasks accept traffic only from the ALB),
   and `public: false` means a worker with no inbound traffic. Calls from private tasks to the
   public ALB leave through the NAT gateway, which is billed per GB; add a private path only
   if that volume becomes significant.
4. **Not yet applied to a real account.** dev / staging / prod plan cleanly against a local AWS
   mock (moto): 104 / 134 / 148 resources.
