# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`platform-engine` (checked out as `~/Dylan/project/platform/terraform/terraform-aws-platform`). **There are exactly
two repositories:**

| | Owns | Never contains |
|---|---|---|
| **platform-engine** (this repo) | developer `config.yaml`, validation, defaults, environment and security policy, composition, state, GitLab CI/CD | reusable modules, the Helm chart |
| **terraform-module** (`../terraform-root-module`) | reusable infrastructure modules with typed inputs, module contract tests | YAML parsing, developer configuration, environment policy |

Do not create a third repository or folder, and do not move responsibilities across this line: a
missing infrastructure capability is a module change there; a developer option, default or policy
is a change here. The policy for the pair is in `../../../CLAUDE.md`.

## Commands

`terraform/` holds **three roots and one shared module**:

```
env/<env>/        config.yaml + backend.hcl (bucket and lock table; CI sets key per stack)
modules/config/   yamldecode → defaults → validation → policy → per-runtime mapping. No AWS resource.
base/             vpc kms security-groups iam ecr cloudwatch rds elasticache   state platform/<env>/base
ecs/              ecs-cluster ecs-service alb acm route53                      state platform/<env>/ecs
eks/              eks cluster, node groups, addons, irsa                       state platform/<env>/eks
```

`base` owns the foundation and the data layer; `ecs` and `eks` read it through
`data.terraform_remote_state.base` and build only the services placed on them. `platform.type` is
the environment default and `services.<name>.platform` overrides it, so one environment can run both
runtimes while services migrate. On eks, Terraform builds no Kubernetes object: CI's deploy job
installs one Helm release per service from `output "helm_deployment"`.

The chart is **not** in this repo: `config.yaml` pins `charts/application` from helm-project, which
publishes it to the ECR chart registry, the same way `main.tf` pins a terraform-module tag and
`services.<name>.image` pins an image. Never vendor a copy of it here — `dev-app-no01` deploys that
same chart, and a second copy would drift.

```bash
cd terraform
terraform fmt -check -recursive
for d in modules/config base ecs eks; do (cd $d && terraform init -backend=false && terraform validate && terraform test); done

cd base                                                # apply base before any runtime stack
terraform init -reconfigure -backend-config=../env/dev/backend.hcl -backend-config="key=platform/dev/base.tfstate"
terraform plan -var environment=dev -out=tfplan

cd ../eks                                              # a runtime stack also needs base's state
terraform init -reconfigure -backend-config=../env/dev/backend.hcl -backend-config="key=platform/dev/eks.tfstate"
terraform plan -var environment=dev -var base_state_bucket=<bucket> -var base_state_region=<region> -out=tfplan
```

Checking a `config.yaml` costs nothing: `modules/config` has no provider and no AWS module, so it
initialises instantly. This is exactly what CI's validate job does:

```bash
cd terraform/modules/config
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf && terraform init -input=false
echo 'concat(local.config_errors, local.policy_errors)' | terraform console -var environment=dev
echo 'local.placement' | terraform console -var environment=dev
rm backend_override.tf
```

A full plan without an AWS account runs against moto with a `providers_override.tf` pointing every
endpoint at it — only in a scratch copy, never in the repo. To try an unreleased module, point
its `source` at `../../terraform-root-module/modules/<name>` in that copy.

Rendering a release the way `helm-validate` does, against a local helm-project checkout:

```bash
cd terraform/modules/config
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf && terraform init -input=false
echo 'base64encode(jsonencode({ for k, r in local.release_specs : k => r.values }))' \
  | terraform console -var environment=dev -var config_path=tests/fixtures/eks_valid_dev.yaml \
  | tr -d '"' | base64 -d | jq .api > /tmp/values.json
rm backend_override.tf
cd ../../..                                          # the repository root
CHART=../../helm-project/charts/application
helm lint --strict $CHART -f /tmp/values.json
helm template api $CHART -f /tmp/values.json | kubeconform -strict -kubernetes-version 1.31.0 \
  -schema-location default -schema-location "$CRD_SCHEMAS"
```

## How a config becomes infrastructure

- `modules/config/main.tf` — `yamldecode` inside `try()` (a syntax error becomes a readable config error),
  `local.environments` (per-environment defaults), `local.sizes`, `local.services` (normalized),
  `local.service_specs` (exact ECS inputs, empty on eks) and `local.release_specs` (Helm values,
  empty on ecs). Neither may reference a module output — the contract tests evaluate them without
  planning AWS; `outputs.tf` adds the RDS/Redis connection env to the Helm values.
- `modules/config/validation.tf` — **layer 1**, `local.config_errors`: is the config well-formed?
- `modules/config/policy.tf` — **layer 2**, `local.policy_errors`: is a well-formed config allowed in this
  environment? Both are enforced by `terraform_data.config` preconditions; layer 3 (can AWS build
  it) is the modules' own validation.
- `<stack>/main.tf` — composition. Every `source` across the three stacks pins the same `?ref=`;
  CI fails if they differ.
- Secrets on eks are `externalSecret` values (ESO), never Kubernetes objects built here:
  `secret_store.provider` picks the `ClusterSecretStore`, `<key>#<property>` becomes
  `remoteRef.key` / `remoteRef.property`, and `injectEnvFrom` puts the synced Secret on the pod.
  ECS keeps reading Secrets Manager and SSM ARNs with its execution role.
- `local.release_specs` emits the **chart's** value names (`service.targetPort`, `extraVolumes`,
  `podDisruptionBudget.maxUnavailable`, …). That chart's `values.schema.json` accepts unknown keys,
  so a misspelled key is silently ignored there — `tests/eks.tftest.hcl` and the `helm-validate`
  render are what catch it. Read helm-project's `charts/application/values.yaml` before adding one.
- `ci/unknown-values-keys.jq` — the guard behind `helm-validate`: every key `release_specs` emits
  must exist in the chart's `values.yaml`, stopping at a chart node that is null, empty or a list
  (a probe handler, a volume), which is free-form.
- `ci/terraform.gitlab-ci.yml`, `ci/helm.gitlab-ci.yml` — templates. `.gitlab-ci.yml` runs
  `plan:base` → `apply:base` (manual) → `plan` (ecs and eks) → `apply` (manual) → `deploy`, so a
  runtime plans against the foundation it will run on. `workflow:rules` allows only the `dev`,
  `staging` and `prod` branches and merge requests targeting them.

A new developer key needs: normalization in `modules/config/main.tf`, the key in the unknown-key
lists and a check in `validation.tf`, an output if a stack needs it, wiring in `ecs/main.tf` or in
`release_specs` + the chart, and a fixture + run in `modules/config/tests/`. A key only one runtime
implements is rejected on the other — `platform_only_keys` keys off `local.runtime_in_use`, not off
`platform.type`, because a mixed environment uses both sets.

## Traps

- **Anything that decides `count`/`for_each` must be known at plan.** Image URIs come from
  `account_id` + `region`, not `module.ecr` outputs; `enable_load_balancer` and `service_connect`
  are decided from config, the ARNs only fill values.
- **`terraform test` sees locals only if the targeted resource depends on them** — the `can()`
  terms in `terraform_data.config`'s precondition exist for this; a new asserted local must be
  reachable from them or Terraform 1.9 panics.
- Index a counted module with `for m in module.x` or `one(module.x[*].attr)`, never `[0]` in an
  expression evaluated when the block is disabled.
- All services listen on 8080 (`local.service_port`) and reach each other at
  `http://<name>:8080` through Service Connect or the Kubernetes Service; more than one public
  service needs `dns.domain`.
- **base is applied first.** A runtime stack reads `data.terraform_remote_state.base`; it cannot
  plan against an environment whose base has never been applied. Anything both runtimes share —
  network, keys, registry, database, cache, the alarm topic — belongs in base, and reaches them as
  a base output, never as a second copy.
- **Terraform owns no Kubernetes object.** No `kubernetes`/`helm` provider in this root: the plan
  must not need the cluster API, and Helm alone owns what runs in it.
- `helm-validate` and `deploy` both pull the chart from ECR, so both the plan role and the apply
  role need cross-account read on the chart registry.
- Resource names are unchanged from the single-root layout (`platform-<env>-*`), but every address
  moved state file: `module.vpc` now lives in base's state, `module.ecs_service` in ecs's. Renaming
  a module or `name_prefix` still replaces live infrastructure.
- `config.yaml` is a public API — rename or remove a key only with a migration for every
  environment.
