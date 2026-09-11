# platform-engine

The developer-facing AWS platform. You describe what your service needs in one `config.yaml`;
the platform validates it, applies environment policy, and turns it into infrastructure built
from the reusable modules of [terraform-module](https://github.com/phuocnguyennb19-ui/terraform-module).

```
                     Developer
                         │  terraform/{ecs,eks}/<env>/config.yaml
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

**Two stacks.** `terraform/ecs/` runs services on ECS Fargate; `terraform/eks/` runs them on EKS
as Helm releases. They are independent Terraform roots — each builds its own VPC, KMS keys,
database and cache, and keeps its own state — so a service lives in exactly one of them.

```
terraform/
├── ecs/  *.tf · tests/ · dev|staging|prod/{config.yaml,backend.hcl}   state key platform/<env>/…
└── eks/  *.tf · tests/ · dev|staging|prod/{config.yaml,backend.hcl}   state key eks/<env>/…
```

---

## For developers: `config.yaml` on ECS — `terraform/ecs/<env>/config.yaml`

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
terraform/ecs/dev/config.yaml is invalid:

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

## For developers: `config.yaml` on EKS — `terraform/eks/<env>/config.yaml`

```yaml
environment: dev
account_id: "111122223333"
region: ap-southeast-1

chart:                            # required; one chart for every service, promoted env by env
  repository: oci://111122223333.dkr.ecr.ap-southeast-1.amazonaws.com/charts
  name: application
  version: "2.0.0"                # exact version, never a range

cluster:
  access:                         # EKS access entries; the CI plan role needs admin-view
    gitlab-plan:
      principal_arn: "arn:aws:iam::111122223333:role/gitlab-plan"
      policy: admin-view          # view | admin-view | edit | admin; prod: view | admin-view

services:
  payment:
    image: payment:1.4.2          # short name → <account>.dkr.ecr.<region>.amazonaws.com/eks/payment
    size: medium
    replicas: 2
    health_check: /healthz
    autoscaling: { min: 2, max: 10 }
    env:
      LOG_LEVEL: info

database: { enabled: true, size: small }
cache:    { enabled: false }
```

| You write | You get |
|---|---|
| `services.<name>` | Helm release `<name>` of `chart` in namespace `platform`: Deployment, Service `http://<name>:8080`, an ECR repository `eks/<image>` |
| `size` | requests `small` 250m / 512Mi · `medium` 500m / 1Gi · `large` 1 / 2Gi; memory limit = request, no CPU limit |
| `health_check` | readiness probe on that path; liveness is a TCP check, so a failing dependency never restarts pods |
| `autoscaling` | HorizontalPodAutoscaler; a PodDisruptionBudget wherever at least 2 pods run |
| `database.enabled` / `cache.enabled` | as on ECS; releases get `DATABASE_HOST/PORT/NAME`, `REDIS_HOST/PORT` |

Not on EKS yet: `public` (needs the AWS Load Balancer Controller) and `secrets` (needs External
Secrets or the Secrets Store CSI driver) — both are rejected as unknown keys, not ignored.
Releases are `atomic`: a failed upgrade rolls back to the previous revision.

**Before the first apply:** publish the chart to `chart.repository` (`helm push
application-2.0.0.tgz oci://…/charts`); give the plan role an access entry through
`cluster.access` (the apply role creates the cluster and holds cluster admin); and make sure the
CI runners reach the EKS API — dev and staging allow `eks_public_api_cidrs`, prod's endpoint is
private, so prod plan and apply need a runner inside the VPC.

---

## Environment policy

Set in `terraform/<stack>/config.tf` (`local.environments`) and `terraform/<stack>/policy.tf` —
never in `config.yaml`, so no config can opt out of it. The table is ECS; EKS uses VPCs
`10.11/10.21/10.31.0.0/16`, the same retention and database policy, the node groups in
`terraform/eks/config.tf`, and in prod a private API endpoint and view-only access from config.

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
cd terraform/ecs                # or terraform/eks
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

`terraform/ecs/tests/platform.tftest.hcl` pins the developer contract: fixtures in
`terraform/ecs/tests/fixtures/` must map to exact module inputs (size → CPU/memory, image → ECR URI,
secret ARN → execution-role grant, prod defaults), and invalid or disallowed configs must fail
— unknown keys, bad sizes and replica counts, `:latest`, a secret value in `env`, an unquoted
ARN, a missing account, a prod config with one replica or public HTTP. The runs target
`terraform_data.config`, so no AWS resource is planned and no credentials are needed.

`terraform/eks/tests/eks.tftest.hcl` does the same for Helm values (size → requests, image →
repository and tag, probes, HPA and PDB, access entries) and rejects a chart version range, a
missing chart, cluster admin from config and edit access in prod.

```bash
cd terraform/ecs && terraform init -backend=false && terraform test   # Terraform >= 1.7; same in terraform/eks
```

---

## CI/CD

`.gitlab-ci.yml` includes the templates in `ci/terraform.gitlab-ci.yml` (`.tf-validate`,
`.tf-contract-test`, `.tf-plan`, `.tf-apply`). There is one `plan` and one `apply` job; the branch
is the environment. `workflow:rules` runs a pipeline only for the `dev`, `staging` and `prod`
branches and merge requests targeting them, and each job's `rules` set `TF_ENV` from that branch.
Every job runs once per stack through `parallel:matrix` (`STACK: [ecs, eks]`), in
`terraform/<stack>/`.

```
merge request → dev | staging | prod           TF_ENV = target branch
  validate         fmt · one ?ref= for every module · terraform validate · every config.yaml (layers 1+2)
  contract-tests   terraform test (Terraform 1.9.8, mocked provider)
  plan             the log lists addresses and actions only
push / Run pipeline on dev | staging | prod    TF_ENV = branch
  validate, contract-tests, plan               again, from the pushed commit
  apply            manual; applies that pipeline's saved plan — never re-plans
                   one apply per stack and environment at a time
```

Promotion is a merge between environment branches (`dev` → `staging` → `prod`). Other branches,
including the default branch, run no pipeline.

| Variable | Where | Meaning |
|---|---|---|
| `TF_ENV` | `rules` of `plan` / `apply` | `dev` / `staging` / `prod`, taken from the branch |
| `STACK` | `.stacks` matrix | `ecs` / `eks` — the Terraform root under `TF_ROOT` |
| `TF_VERSION`, `TF_TEST_VERSION`, `TF_ROOT` | `.gitlab-ci.yml` | deploy CLI 1.5.7, test CLI 1.9.8, Terraform directory |
| `AWS_PLAN_ROLE_ARN` | CI/CD variable, scoped to each environment | read-only plan role — not protected, MR pipelines need it |
| `AWS_APPLY_ROLE_ARN` | CI/CD variable, scoped to each environment, **protected** | deploy role — only protected branches see it |

**Plan artifacts.** The saved plan holds resolved values in plaintext (`sensitive` only hides
them from the console). It is kept one day, visible to developers and above only, and never
printed: the job log shows resource addresses and actions, not attribute values.

**Safety.** Apply runs the saved plan of the same pipeline; if state moved since, Terraform
refuses the stale plan. `resource_group` serialises applies per stack and environment and the DynamoDB lock
guards the state. The `dev`, `staging` and `prod` branches must be protected (the apply role
variable is protected), and prod apply needs a protected `prod` environment with required approvers.

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

// apply role — only that account's environment branch (dev | staging | prod); deploy permissions, never AdministratorAccess
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<gitlab-host>" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "<gitlab-host>:aud": "https://<gitlab-host>",
      "<gitlab-host>:sub": "project_path:<group>/platform-engine:ref_type:branch:ref:<env>"
    }
  }
}
```

Give the apply role a permissions boundary so the roles it creates (ECS task and execution roles,
RDS monitoring) cannot exceed it.

---

## State

`terraform/<stack>/<env>/backend.hcl` names the bucket, key, region and lock table; the key contains the
environment and CI checks it, so environments never share state. The stacks share the bucket and
lock table of an account under different keys (`platform/<env>/` for ECS, `eks/<env>/` for EKS). Terraform 1.5.7 locks through a
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

Every module `source` in `terraform/<stack>/main.tf` pins the same terraform-module tag; CI fails if two
differ, so an environment always runs one tested module set. Both stacks pin the same tag.

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
   in every `backend.hcl`; `staging.example.com` / `example.com` must be real delegated zones. On
   EKS also `chart.repository` and the `cluster.access` role ARN, and `eks_public_api_cidrs`
   (`203.0.113.0/24`, a documentation range) in `terraform/eks/config.tf` must become the runners' range.
3. **One container port (8080) for every service** — the security groups open one application
   port from the ALB and between tasks.
4. **Not yet applied to a real account.** ECS dev / staging / prod plan cleanly against a local AWS
   mock (moto): 107 / 137 / 151 resources. The EKS stack has passed validate, its contract tests
   and a `helm template` of the chart with its values, but no plan: Helm needs a real cluster.
5. **EKS: Helm releases share state with the cluster that serves them.** The helm provider is
   configured from `module.eks`, so replacing the cluster needs a plan that removes the releases first.
