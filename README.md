# platform-engine

The developer-facing AWS platform. You describe what your service needs in one `config.yaml`;
the platform validates it, applies environment policy, and turns it into infrastructure built
from the reusable modules of [terraform-module](https://github.com/phuocnguyennb19-ui/terraform-module).

```
                     Developer
                         │  terraform/<env>/config.yaml
                         ▼
  ┌──────────────────────────────────────────────────┐
  │ platform-engine (this repo)                      │
  │   config.tf      yamldecode → defaults → sizes   │  Layer 1  validation.tf  is the config valid?
  │   policy.tf      environment policy              │  Layer 2  policy.tf      is it allowed here?
  │   main.tf        composition                     │
  │   ci/, .gitlab-ci.yml   validate → plan → apply  │
  └────────────────────────┬─────────────────────────┘
                           │ typed inputs, one pinned ?ref=
                           ▼
  ┌──────────────────────────────────────────────────┐
  │ terraform-module                                  │  Layer 3  module validation: can AWS
  │   modules/vpc, ecs-*, alb, rds, elasticache, …    │           build this safely?
  └────────────────────────┬─────────────────────────┘
                           ▼
                          AWS
```

**Why two repositories.** Modules change rarely and are reused; they know nothing about YAML,
environments or policy, and are tested and released on their own. Everything a developer or an
environment decides lives here. There is no third repository.

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
    public: true                  # true → https://payment.<dns.domain>; false → private only
    health_check: /healthz        # default /healthz, on port 8080
    autoscaling: { min: 2, max: 10 }
    env:
      LOG_LEVEL: info
    secrets:                      # references only — never a value; quote an ARN ending in "::"
      API_KEY: "arn:aws:secretsmanager:ap-southeast-1:111122223333:secret:payment-AbCdEf:key::"
  ledger:
    image: ledger:2.0.0           # public: false — reached by other services, not the internet

database:
  enabled: true
  size: small                     # small | medium | large

cache:
  enabled: false
  size: small

kubernetes:
  enabled: false                  # optional EKS cluster for the platform team
```

Only `environment`, `account_id` and `region` are required.

| You write | You get |
|---|---|
| `services.<name>` | ECS Fargate service `platform-<env>-<name>`, logs, alarms, an ECR repository named after the image |
| `size` | `small` 0.25 vCPU / 512 MiB · `medium` 0.5 vCPU / 1 GiB · `large` 1 vCPU / 2 GiB |
| `public: true` | a target group on the shared ALB; with `dns.domain`, `https://<name>.<domain>` and a wildcard certificate |
| every service | a private address **`http://<name>:8080`** (ECS Service Connect) — call other services here; the call never leaves the VPC |
| `database.enabled` | PostgreSQL 16 (`small` db.t4g.medium · `medium` db.t4g.large · `large` db.r6g.xlarge); every service gets `DATABASE_HOST/PORT/NAME` |
| `cache.enabled` | Redis 7 (`small` cache.t4g.small · `medium` cache.t4g.medium · `large` cache.r7g.large); every service gets `REDIS_HOST/PORT` |
| `secrets` | injected as environment variables at start; the execution role is granted exactly those ARNs |

A mistake fails before anything touches AWS, naming the field:

```
terraform/dev/config.yaml is invalid:

  - Invalid services.payment.size: "xlarge"
    Supported values:
    - small
    - medium
    - large
```

An `env` name that looks like a credential (`PASSWORD`, `SECRET`, `TOKEN`, `PRIVATE_KEY`) is
rejected — put it under `secrets`. The RDS master credentials live in Secrets Manager;
`terraform output database_master_secret_arn` gives the ARN to reference.

**What the developer never sets:** CPU units, task/execution roles, target groups, health-check
timings, deployment percentages, security groups, subnets, KMS keys. `ecs-service` exposes 43
inputs; platform-engine sets them from `size`, `replicas`, `public`, `autoscaling`, `secrets` and
the environment policy below.

---

## Environment policy

Set in `terraform/config.tf` (`local.environments`) and `terraform/policy.tf` — never in
`config.yaml`, so no config can opt out of it.

| | dev (cost) | staging (production-like) | prod (availability) |
|---|---|---|---|
| VPC CIDR / AZs | `10.10.0.0/16`, 2 | `10.20.0.0/16`, 3 | `10.30.0.0/16`, 3 pinned |
| NAT gateways | 1 shared | one per AZ | one per AZ |
| Log / flow-log retention | 7 days | 30 days | 365 days |
| Default replicas | 1 | 2 | 2 — **fewer is rejected** |
| RDS | single-AZ, 3-day backups | multi-AZ, 7 days | multi-AZ, 30 days, deletion protection |
| ALB deletion protection | off | off | on |
| ECS Exec | on | on | off |
| Public traffic | HTTP or HTTPS | HTTP or HTTPS | **HTTPS only** (`dns.domain` required) |

**NAT trade-off.** One shared NAT gateway costs one gateway but an AZ outage cuts egress for the
whole VPC; one per AZ removes that failure mode at roughly 2–3× the NAT cost. dev takes the risk,
staging and prod do not. Service-to-service calls go through Service Connect, not NAT, so NAT
carries only egress to the internet and AWS APIs (prod also has VPC interface endpoints).

**Network model.** Internet → ALB (443/80 from `0.0.0.0/0`, public ALB only) → ECS tasks
(8080, from the ALB security group) → RDS 5432 / Redis 6379 (from the ECS security group). Tasks
reach each other on 8080 by security-group reference. Tasks have no public IP; egress is via NAT.

---

## Running it locally

```bash
cd terraform
terraform init -reconfigure -backend-config=dev/backend.hcl
terraform plan -var environment=dev -out=tfplan
terraform apply tfplan          # applies exactly what was planned
```

Switching environment means `init -reconfigure` against that environment's `backend.hcl` — the
config and the state always travel together. The provider refuses to run with credentials for
any account other than `account_id` (`allowed_account_ids`).

Check a config without AWS (what CI's validate job does):

```bash
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf && terraform init -input=false
echo 'concat(local.config_errors, local.policy_errors)' | terraform console -var environment=dev
rm backend_override.tf
```

---

## Tests

`terraform/tests/platform.tftest.hcl` pins the developer contract: fixtures in
`terraform/tests/fixtures/` must map to exact module inputs (size → CPU/memory, image → ECR URI,
secret ARN → execution-role grant, prod defaults), and invalid or disallowed configs must fail
— unknown keys, bad sizes and replica counts, `:latest`, a secret value in `env`, an unquoted
ARN, a missing account, a prod config with one replica or public HTTP. The runs target
`terraform_data.config`, so no AWS resource is planned and no credentials are needed.

```bash
cd terraform && terraform init -backend=false && terraform test   # Terraform >= 1.7
```

---

## CI/CD

`.gitlab-ci.yml` includes the templates in `ci/terraform.gitlab-ci.yml` (`.tf-validate`,
`.tf-contract-test`, `.tf-plan`, `.tf-apply`); each environment job only sets `TF_ENV`.

```
merge request
  validate         fmt · one ?ref= for every module · terraform validate · every config.yaml (layers 1+2)
  contract-tests   terraform test (Terraform 1.9.8, mocked provider)
  plan:<env>       only for environments whose files changed; the log lists addresses and actions only
merge → default branch
  plan:<env>       again, from the merge commit
  apply:<env>      manual; applies that pipeline's saved plan — never re-plans
                   staging waits for dev, prod for staging; one apply per environment at a time
```

| Variable | Where | Meaning |
|---|---|---|
| `ENVIRONMENT` | **Run pipeline** form | `dev` / `staging` / `prod` runs only that environment; empty: every environment whose files changed |
| `TF_VERSION`, `TF_TEST_VERSION`, `TF_ROOT` | `.gitlab-ci.yml` | deploy CLI 1.5.7, test CLI 1.9.8, Terraform directory |
| `AWS_PLAN_ROLE_ARN` | CI/CD variable, scoped to each environment | read-only plan role — not protected, MR pipelines need it |
| `AWS_APPLY_ROLE_ARN` | CI/CD variable, scoped to each environment, **protected** | deploy role — only protected branches see it |

**Plan artifacts.** The saved plan holds resolved values in plaintext (`sensitive` only hides
them from the console). It is kept one day, visible to developers and above only, and never
printed: the job log shows resource addresses and actions, not attribute values.

**Safety.** Apply runs the saved plan of the same pipeline; if state moved since, Terraform
refuses the stale plan. `resource_group` serialises applies per environment and the DynamoDB lock
guards the state. prod apply needs a protected `prod` environment with required approvers.

### AWS authentication — OIDC, no stored keys

GitLab issues an ID token (`aud` = the GitLab URL); AWS STS exchanges it for a role. Two roles
per account:

```jsonc
// plan role — any branch of this project; attach ReadOnlyAccess + state read/lock only
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<gitlab-host>" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "<gitlab-host>:aud": "https://<gitlab-host>" },
    "StringLike":   { "<gitlab-host>:sub": "project_path:<group>/platform-engine:ref_type:branch:ref:*" }
  }
}

// apply role — the default branch only; deploy permissions, never AdministratorAccess
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<gitlab-host>" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "<gitlab-host>:aud": "https://<gitlab-host>",
      "<gitlab-host>:sub": "project_path:<group>/platform-engine:ref_type:branch:ref:main"
    }
  }
}
```

Give the apply role a permissions boundary so the roles it creates (ECS task and execution roles,
RDS monitoring) cannot exceed it.

---

## State

`terraform/<env>/backend.hcl` names the bucket, key, region and lock table; the key contains the
environment and CI checks it, so environments never share state. Terraform 1.5.7 locks through a
DynamoDB table (`use_lockfile` needs ≥ 1.10). Create the bucket and table once per account:

```bash
BUCKET=my-terraform-state-dev
REGION=ap-southeast-1

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"DenyInsecureTransport\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"],\"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}}]}"
aws dynamodb create-table --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region "$REGION"
```

Only the plan and apply roles may read the bucket; the plan role needs `s3:GetObject` and the lock
table, the apply role also `s3:PutObject`. State and saved plans are sensitive.

---

## Versioning

Every module `source` in `terraform/main.tf` pins the same terraform-module tag; CI fails if two
differ, so an environment always runs one tested module set.

| platform-engine | terraform-module | Notes |
|---|---|---|
| `main` (this layout) | `v2.0.0` | typed-only modules, Service Connect, contract tests |
| earlier (clone-and-copy CI) | `v1.2.1` – `v1.3.0` | YAML engine at the module repo root |

Upgrading: bump every `?ref=` together, read terraform-module's `CHANGELOG.md`, plan every
environment. `config.yaml` is a public API — a key is renamed or removed only with a migration
for every environment.

---

## Known limitations

1. **terraform-module `v2.0.0` must be tagged and pushed** before `init` works.
2. **Placeholders:** `account_id: "REPLACE-ME"` and `image: api:REPLACE-ME` in every
   `config.yaml` (validate fails until `account_id` is real); the `REPLACE-ME` bucket and lock table
   in every `backend.hcl`; `staging.example.com` / `example.com` must be real delegated zones.
3. **One container port (8080) for every service** — the security groups open one application
   port from the ALB and between tasks.
4. **Not yet applied to a real account.** dev / staging / prod plan cleanly against a local AWS
   mock (moto): 107 / 137 / 151 resources.
