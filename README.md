# platform-engine

The developer-facing AWS platform. You describe what your service needs in one `config.yaml`;
the platform validates it, applies environment policy, and turns it into infrastructure built
from the reusable modules of [terraform-module](https://github.com/phuocnguyennb19-ui/terraform-module).

```
                     Developer
                         │  terraform/env/<env>/config.yaml   platform.type, services.<name>.platform
                         ▼
  ┌──────────────────────────────────────────────────┐
  │ platform-engine (this repo)                      │
  │   config.tf      yamldecode → defaults → sizes   │  Layer 1  validation.tf  is the config valid?
  │   policy.tf      environment policy              │  Layer 2  policy.tf      is it allowed here?
  │   main.tf        composition                     │
  │   ci/, .gitlab-ci.yml   validate → plan → apply  │
  │                         → deploy (Helm, eks only) │
  └───────┬────────────────┬─────────────────────────┘
          │                │ pinned chart, pulled at deploy
          │                ▼
          │      helm-project/charts/application
          │      (published to the ECR chart registry by its own pipeline)
                           │ typed inputs, one pinned ?ref=
                           ▼
  ┌──────────────────────────────────────────────────┐
  │ terraform-module                                  │  Layer 3  module validation: can AWS
  │   modules/vpc, ecs-*, alb, rds, elasticache, …    │           build this safely?
  └────────────────────────┬─────────────────────────┘
                           ▼
                          AWS ──── ECS services            (platform ecs: Terraform deploys them)
                           └────── EKS cluster ── Helm ── Deployments   (platform eks: CI's deploy job)
```

**Why two repositories.** Modules change rarely and are reused; they know nothing about YAML,
environments or policy, and are tested and released on their own. Everything a developer or an
environment decides lives here. There is no third repository.

**Three stacks, one config.** `base` builds everything the services sit on; `ecs` and `eks` build the
runtimes. Each has its own state, so a cluster upgrade cannot block an ECS deploy, and an
environment can run **both runtimes at once** while services move between them one at a time.
`platform.type` sets the environment's default, and `services.<name>.platform` overrides it:

| | a service on `ecs` | a service on `eks` |
|---|---|---|
| Terraform builds | ECS cluster, one ECS service per entry, ALB, DNS, certificate | EKS cluster, node groups, add-ons, IRSA — no Kubernetes objects |
| Services deployed by | `terraform apply` | CI's `deploy` job: one Helm release of the pinned chart per service |
| Service-to-service | `http://<name>:8080` (Service Connect) | `http://<name>:8080` (Kubernetes Service) |
| Logs / metrics | CloudWatch Logs, `AWS/ECS` | CloudWatch Logs via Fluent Bit, Container Insights |

```
terraform/
├── env/<env>/         config.yaml · backend.hcl (bucket and lock table; CI sets the key per stack)
├── modules/config/    the mapping, validation and policy all three stacks read — no AWS resource
│   └── tests/         the developer contract: 34 runs
├── base/              vpc · kms · security groups · iam · ecr · cloudwatch · rds · elasticache
├── ecs/               ecs cluster · services · alb · acm · route53        reads base
└── eks/               eks cluster · node groups · addons · irsa           reads base
ci/                    terraform.gitlab-ci.yml · helm.gitlab-ci.yml
```

`base` owns the data layer, so a service reaches the **same** database and cache whichever runtime
it runs on — moving one from ECS to EKS does not move its data. The runtimes read what base built
through its state, never by guessing at names.

```yaml
services:
  payment:
    image: payment:1.4.2        # runs on the environment's platform.type
  ledger:
    image: ledger:2.0.0
    platform: eks               # …this one has moved already
```

**The chart is not in this repository.** EKS releases install `charts/application` from
[helm-project](https://github.com/phuocnguyennb19-ui/helm-project), which lints, packages, scans and
publishes it to the shared ECR chart registry — the same chart `dev-app-no01` deploys. This repo
pins `chart.repository`, `chart.name` and `chart.version`, exactly as it pins a terraform-module tag
or an image tag. A chart of its own here would be a second `application` chart in the estate,
diverging from the published one.

Terraform never creates a Kubernetes object and Helm never creates an AWS resource: Terraform
turns `config.yaml` into each service's Helm values (`output "helm_deployment"`), and the deploy
job installs them. Changing an environment's `platform.type` replaces its whole runtime in one plan
— review that plan like the migration it is.

---

## For developers: `config.yaml` — `terraform/env/<env>/config.yaml`

### On ECS

```yaml
environment: dev                  # must match the folder name
account_id: "111122223333"        # quoted: an unquoted ID loses leading zeros
region: ap-southeast-1

platform:
  type: ecs                       # ecs | eks

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
  enabled: false                  # optional EKS cluster beside ECS, for the platform team
```

Only `environment`, `account_id`, `region` and `platform.type` are required.

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

### On EKS

The same `services`, `database` and `cache` keys, with `platform.type: eks`:

```yaml
environment: dev
account_id: "111122223333"
region: ap-southeast-1

platform:
  type: eks

chart:                            # required on eks; the published application chart
  repository: oci://999988887777.dkr.ecr.ap-southeast-1.amazonaws.com/charts
  name: application
  version: "2.0.0"                # exact version, never a range — promoted env by env

eks:
  access:                         # optional EKS access entries for people and tools
    developers:
      principal_arn: "arn:aws:iam::111122223333:role/developers"
      policy: view                # view | admin-view | edit | admin; prod: view | admin-view

services:
  payment:
    image: payment:1.4.2          # same ECR repository as on ECS: <account>.dkr.ecr.<region>.amazonaws.com/payment
    size: medium
    replicas: 2
    health_check: /healthz
    autoscaling: { min: 2, max: 10 }
    env:
      LOG_LEVEL: info

secret_store:                     # where secrets come from: aws or vault
  provider: aws                   # name: defaults to aws-secretsmanager, or vault

database: { enabled: true, size: small }
cache:    { enabled: false }
```

| You write | You get |
|---|---|
| `services.<name>` | Helm release `<name>` of the pinned chart in namespace `platform`: Deployment, Service `http://<name>:8080`, its own ServiceAccount (no API token mounted) |
| `size` | requests `small` 250m / 512Mi · `medium` 500m / 1Gi · `large` 1 / 2Gi; memory limit = request, no CPU limit |
| `health_check` | readiness probe on that path; liveness is a TCP check, so a failing dependency never restarts pods |
| `autoscaling` | HorizontalPodAutoscaler on CPU (metrics-server add-on); a PodDisruptionBudget wherever at least 2 pods run |
| `database.enabled` / `cache.enabled` | as on ECS; releases get `DATABASE_HOST/PORT/NAME`, `REDIS_HOST/PORT` |
| `services.<name>.secrets` | an `ExternalSecret` per service; External Secrets pulls each reference into a Kubernetes Secret, and the pod gets it as environment variables |

The chart's own defaults do the hardening: pods run as UID 10001 with a read-only root filesystem
(the platform mounts an `emptyDir` at `/tmp`), no privilege escalation, every capability dropped and
no ServiceAccount token mounted. The deploy job labels the namespace with the Kubernetes
`restricted` Pod Security standard, so an image must run as a non-root user. A rolling update never
drops below the desired replica count.

**Secrets, two ways.** `secret_store.provider` decides where a reference points; nothing else in the
config changes:

```yaml
services:
  payment:
    secrets:
      API_KEY: "platform/payment#api_key"      # <key>#<property>, property optional
```

| `provider` | The key is | Needs |
|---|---|---|
| `aws` | a Secrets Manager secret name or a full ARN | External Secrets with an IRSA role that can read it |
| `vault` | a KV path | External Secrets with a Vault `ClusterSecretStore` — no AWS anywhere in this path, so it also works on a cluster that is not EKS |

The store itself is cluster tooling installed with the rest of the platform components; this repo
only names it. On ECS the key is unchanged — a Secrets Manager or SSM ARN read by the task
execution role — so `secret_store` is rejected there.

Not on EKS yet — rejected with a message, never ignored: `public` (needs the AWS Load Balancer
Controller), `dns` (only publishes public services) and `kubernetes` (ECS only). `eks`, `chart` and
`secret_store` are rejected on ECS.

**Before the first apply:**

1. `chart.version` must already be published to `chart.repository` by helm-project's chart pipeline.
2. Both CI roles need to pull it: the **plan** role (helm-validate renders the chart) and the
   **apply** role (deploy installs it). The chart registry lives in the shared infra account, so
   this is a cross-account ECR read — grant it in that registry's repository policy.
3. The `tf-apply-runner` must reach the EKS API for the deploy job. dev and staging allow
   `eks_public_api_cidrs`; prod's endpoint is private, so prod needs a runner inside the VPC. The
   plan and apply jobs themselves never talk to the cluster.

---

## Environment policy

Set in `terraform/config.tf` (`local.environments`) and `terraform/policy.tf` — never in
`config.yaml`, so no config can opt out of it. On EKS the same table applies, plus the node groups
in `local.environments`, a private API endpoint in prod, and view-only access from config in prod.

| | dev (cost) | staging (production-like) | prod (availability) |
|---|---|---|---|
| VPC CIDR / AZs | `10.10.0.0/16`, 2 | `10.20.0.0/16`, 3 | `10.30.0.0/16`, 3 pinned |
| NAT gateways | 1 shared | one per AZ | one per AZ |
| Log / flow-log retention | 7 days | 30 days | 365 days |
| Default replicas | 1 | 2 | 2 — **fewer is rejected** |
| RDS | single-AZ, 3-day backups | multi-AZ, 7 days | multi-AZ, 30 days, deletion protection |
| ALB deletion protection | off | off | on |
| ECS Exec | on | on | off |
| EKS API endpoint | public, runner CIDRs | public, runner CIDRs | **private** |
| Public traffic | HTTP or HTTPS | HTTP or HTTPS | **HTTPS only** (`dns.domain` required) |

**NAT trade-off.** One shared NAT gateway costs one gateway but an AZ outage cuts egress for the
whole VPC; one per AZ removes that failure mode at roughly 2–3× the NAT cost. dev takes the risk,
staging and prod do not. Service-to-service calls go through Service Connect, not NAT, so NAT
carries only egress to the internet and AWS APIs (prod also has VPC interface endpoints).

**Network model.** Internet → ALB (443/80 from `0.0.0.0/0`, public ALB only) → ECS tasks
(8080, from the ALB security group) → RDS 5432 / Redis 6379 (from the ECS security group). Tasks
reach each other on 8080 by security-group reference. Tasks have no public IP; egress is via NAT.
On EKS pods get VPC addresses on private subnets (VPC CNI) and reach RDS and Redis the same way; the
node instance role is out of reach of pods (IMDS hop limit 1), so a pod has no AWS permissions
unless an IRSA role is bound to its ServiceAccount.

---

## Running it locally

Each stack is its own root, and each has its own state key. Apply `base` first: the runtimes read
its outputs.

```bash
cd terraform/base
terraform init -reconfigure \
  -backend-config=../env/dev/backend.hcl \
  -backend-config="key=platform/dev/base.tfstate"
terraform plan -var environment=dev -out=tfplan
terraform apply tfplan          # applies exactly what was planned

cd ../ecs                       # or ../eks
terraform init -reconfigure \
  -backend-config=../env/dev/backend.hcl \
  -backend-config="key=platform/dev/ecs.tfstate"
terraform plan -var environment=dev \
  -var base_state_bucket=my-terraform-state-dev -var base_state_region=ap-southeast-1 -out=tfplan
```

On platform eks, install the releases the way the deploy job does (needs an EKS access entry):

```bash
terraform output -json helm_deployment > deploy-dev.json
aws eks update-kubeconfig --name "$(jq -r .cluster_name deploy-dev.json)" --region "$(jq -r .region deploy-dev.json)"

aws ecr get-login-password --region "$(jq -r .region deploy-dev.json)" \
  | helm registry login --username AWS --password-stdin "$(jq -r .chart.registry_host deploy-dev.json)"
helm pull "$(jq -r .chart.ref deploy-dev.json)" --version "$(jq -r .chart.version deploy-dev.json)" --untar --untardir /tmp/chart

for svc in $(jq -r '.releases | keys[]' deploy-dev.json); do
  jq ".releases.\"$svc\"" deploy-dev.json > "values-$svc.json"
  helm upgrade --install "$svc" /tmp/chart/application -n platform -f "values-$svc.json" --atomic --wait --timeout 10m
done
```

Against a checkout of helm-project, `/tmp/chart/application` can be `../../../helm-project/charts/application`
— useful for trying a chart change before it is published, never for a real deployment.

Switching environment means `init -reconfigure` against that environment's `backend.hcl` — the
config and the state always travel together. The provider refuses to run with credentials for
any account other than `account_id` (`allowed_account_ids`).

Check a config without AWS — from `modules/config`, which pulls in no provider and no AWS module,
so it is instant (what CI's validate job does):

```bash
cd terraform/modules/config
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf && terraform init -input=false
echo 'concat(local.config_errors, local.policy_errors)' | terraform console -var environment=dev
echo 'local.placement' | terraform console -var environment=dev      # which runtime each service lands on
rm backend_override.tf
```

---

## Tests

`terraform/modules/config/tests/platform.tftest.hcl` pins the developer contract on ECS: fixtures in
`modules/config/tests/fixtures/` must map to exact module inputs (size → CPU/memory, image → ECR URI,
secret ARN → execution-role grant, prod defaults), and invalid or disallowed configs must fail
— unknown keys, bad sizes and replica counts, `:latest`, a secret value in `env`, an unquoted
ARN, a missing account, a prod config with one replica or public HTTP. The runs target
`terraform_data.config`, so no AWS resource is planned and no credentials are needed.

Missing or unknown `platform.type`, and an `eks` block on ECS, are rejected too.

`modules/config/tests/eks.tftest.hcl` does the same for Helm values (size → requests, image →
repository and tag, probes, HPA and PDB, env, access entries, alarms) and rejects cluster admin
from config, edit access in prod, one replica in prod, and `public`, `secrets` and `dns` on EKS.

The chart is the other half of that contract, and it is versioned outside this repo: `helm-validate`
pulls the exact `chart.version` an environment pins, compares every key `config.tf` emits against
that chart's `values.yaml` (`ci/unknown-values-keys.jq`), and renders every release with it. The
chart's own `values.schema.json` accepts unknown keys, so without that comparison a key the chart
stopped honouring would deploy silently with the chart's default; with it, CI names the key and
fails before apply.

Each stack also has a `tests/plan.tftest.hcl` that plans its whole module graph against a mocked
provider — `base` with a mixed environment, `ecs` and `eks` with base's outputs overridden — so a
composition error surfaces without an AWS account.

```bash
cd terraform/modules/config && terraform init -backend=false && terraform test   # Terraform >= 1.7
cd ../../base && terraform init -backend=false && terraform test                 # same in ecs/ and eks/
```

---

## CI/CD

`.gitlab-ci.yml` includes the templates in `ci/terraform.gitlab-ci.yml` (`.tf-validate`,
`.tf-contract-test`, `.tf-plan`, `.tf-apply`) and `ci/helm.gitlab-ci.yml` (`.helm-validate`,
`.helm-deploy`). There is one `plan`, one `apply` and one `deploy` job; the branch is the
environment. `workflow:rules` runs a pipeline only for the `dev`, `staging` and `prod` branches
and merge requests targeting them, and each job's `rules` set `TF_ENV` from that branch. The jobs
are the same for both platforms; `config.yaml` decides what they build.

```
merge request → dev | staging | prod           TF_ENV = target branch
  validate         fmt · one ?ref= for every module · terraform validate in all three stacks
                   · every config.yaml (layers 1+2), and which runtime each service lands on
                   · no backend.hcl pins a state key · renders the Helm values of every eks config
  contract-tests   terraform test in modules/config and in each stack (Terraform 1.9.8, mocked)
  helm-validate    pulls the pinned chart, checks every value key against the chart's own
                   values.yaml, then helm lint --strict · helm template | kubeconform -strict
                   for every release of this environment — no cluster needed
  plan:base        the foundation
  plan             ecs and eks in parallel, against today's base
push / Run pipeline on dev | staging | prod    TF_ENV = branch
  validate, contract-tests, helm-validate          again, from the pushed commit
  plan:base
  apply:base       manual. An empty plan here is normal — most changes touch a runtime only
  plan             ecs and eks, now against the base that was just applied
  apply            manual, both runtimes in parallel; applies that pipeline's saved plan
  deploy           after apply, automatically. No eks service: nothing to do. Otherwise it pulls
                   the pinned chart, server-side dry-runs every release, then
                   helm upgrade --install --atomic --wait per service
                   every apply and deploy of one environment is serialised against the others
```

**Why two approvals.** A runtime plan is only trustworthy against the foundation it will actually
run on, so on a branch the runtime stacks plan *after* base is applied. On a merge request there is
no apply, so they plan against today's base — enough to review a runtime change, while the base plan
in the same pipeline shows what the foundation would become.

**Helm deployment.** Both the chart version and the image tag come from `config.yaml`, pinned and
never floating — `:latest` is rejected by the config, and the chart itself refuses a tag it cannot
resolve. Each release is `--atomic` with a 10-minute
`HELM_TIMEOUT`: a release that does not become ready rolls back to its previous revision and fails
the job. The job never uninstalls anything — a release whose service left `config.yaml` is named
in a warning with the `helm uninstall` command. Rollback: revert the `config.yaml` change and run
the pipeline (the normal path, it stays in Git); in an emergency, `helm rollback <service>
<revision> -n platform` — `helm history <service> -n platform` lists revisions — then revert the
config, because the next deploy re-applies whatever it says. The Terraform plan shows a release
change as a change to the `helm_deployment` output.

Promotion is a merge between environment branches (`dev` → `staging` → `prod`). Other branches,
including the default branch, run no pipeline.

| Variable | Where | Meaning |
|---|---|---|
| `TF_ENV` | `rules` of `plan` / `apply` / `deploy` | `dev` / `staging` / `prod`, taken from the branch |
| `TF_VERSION`, `TF_TEST_VERSION`, `TF_ROOT` | `.gitlab-ci.yml` | deploy CLI 1.5.7, test CLI 1.9.8, Terraform directory |
| `HELM_IMAGE`, `HELM_TIMEOUT` | `.gitlab-ci.yml` | `alpine/k8s:1.31.13` (helm, kubectl, aws, kubeconform, jq), the per-release wait |
| `AWS_PLAN_ROLE_ARN` | CI/CD variable, scoped to each environment | read-only plan role — not protected, MR pipelines need it; also pulls the chart in helm-validate |
| `AWS_APPLY_ROLE_ARN` | CI/CD variable, scoped to each environment, **protected** | apply and Helm deploy role — only protected branches see it; it creates the EKS cluster, so it holds cluster admin |

**Plan artifacts.** The saved plan holds resolved values in plaintext (`sensitive` only hides
them from the console). It is kept one day, visible to developers and above only, and never
printed: the job log shows resource addresses and actions, not attribute values.

**Safety.** Apply runs the saved plan of the same pipeline; if state moved since, Terraform
refuses the stale plan. `resource_group` serialises apply and deploy per environment and the DynamoDB lock
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
RDS monitoring, EKS cluster, node and IRSA roles) cannot exceed it.

---

## State

`terraform/env/<env>/backend.hcl` names the bucket, region and lock table — **not the key**. CI sets
`key=platform/<env>/<stack>.tfstate` per job, so the three stacks of an environment keep three
separate states and no environment can be pointed at another's. The validate job fails if a
`backend.hcl` pins a key of its own.
Either platform lives in that one state. Terraform 1.5.7 locks through a DynamoDB table
(`use_lockfile` needs ≥ 1.10). Create the bucket and table once per account:

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

Every module `source` in the three stacks pins the same terraform-module tag; CI fails if two
differ, so an environment always runs one tested module set. The chart is pinned the same way, per
environment, in `config.yaml` — so a new chart version is promoted `dev` → `staging` → `prod` by the
same merges, independently of the module tag.

| platform-engine | terraform-module | Notes |
|---|---|---|
| `main` (this layout) | `v2.0.0` | typed-only modules, Service Connect, `eks.cluster_addons[*].irsa_role_key`, contract tests |
| earlier (clone-and-copy CI) | `v1.2.1` – `v1.3.0` | YAML engine at the module repo root |

Upgrading: bump every `?ref=` together, read terraform-module's `CHANGELOG.md`, plan every
environment. `config.yaml` is a public API — a key is renamed or removed only with a migration
for every environment.

---

## Known limitations

1. **terraform-module `v2.0.0` must be tagged and pushed** before `init` works.
2. **Placeholders:** `account_id: "REPLACE-ME"` and `image: api:REPLACE-ME` in every
   `config.yaml` (validate fails until `account_id` is real); the `REPLACE-ME` bucket and lock table
   in every `backend.hcl`; `staging.example.com` / `example.com` must be real delegated zones. For
   EKS, `eks_public_api_cidrs` (`203.0.113.0/24`, a documentation range) in `terraform/config.tf`
   must become the runners' range.
3. **One container port (8080) for every service** — the security groups open one application
   port from the ALB and between tasks.
4. **Not yet applied to a real account.** ECS dev / staging / prod plan cleanly against a local AWS
   mock (moto): 107 / 137 / 151 resources. Both platforms plan the full module graph with a mocked
   provider, and helm-project's `charts/application` renders, passes `kubeconform`, and its pods are
   admitted by a namespace enforcing the `restricted` Pod Security standard on a local cluster —
   but no release has been installed on a real EKS cluster, and no image has been pulled.
5. **EKS: no public services, no secrets yet.** Both need a cluster component this platform does not
   run yet (AWS Load Balancer Controller; External Secrets or the Secrets Store CSI driver) and are
   rejected on EKS until one is chosen.
6. **A runtime stack cannot plan before base has been applied once.** It reads base's state; on a
   fresh environment apply `base` first. CI's ordering does that for you.
7. **EKS secrets need a `ClusterSecretStore` that exists.** The platform names it and renders the
   `ExternalSecret`; installing External Secrets and its store (AWS or Vault) is cluster tooling,
   outside this repo. A missing store leaves the Secret unsynced and the pods without those variables.
8. **EKS: deploys are per service, in order.** If the third of five releases fails, it rolls back and
   the job stops; the first two stay upgraded. Re-running the job converges the rest.
