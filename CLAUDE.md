# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`platform-engine` (checked out as `~/Dylan/project/terraform-aws-platform`). **There are exactly
two repositories:**

| | Owns | Never contains |
|---|---|---|
| **platform-engine** (this repo) | developer `config.yaml`, validation, defaults, environment and security policy, composition, state, GitLab CI/CD | reusable modules |
| **terraform-module** (`../terraform-root-module`) | reusable infrastructure modules with typed inputs, module contract tests | YAML parsing, developer configuration, environment policy |

Do not create a third repository or folder, and do not move responsibilities across this line: a
missing infrastructure capability is a module change there; a developer option, default or policy
is a change here. The policy for the pair is in `../CLAUDE.md`.

## Commands

```bash
cd terraform
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform test                                   # contract tests, Terraform >= 1.7
docker run --rm -v "$PWD":/w -w /w hashicorp/terraform:1.9.8 test   # without a local 1.7+

terraform init -reconfigure -backend-config=dev/backend.hcl         # real state
terraform plan -var environment=dev -out=tfplan
```

Checking a `config.yaml` without AWS needs a throwaway local backend (`*_override.tf` is
gitignored) — exactly what CI's validate job does:

```bash
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf && terraform init -input=false
echo 'concat(local.config_errors, local.policy_errors)' | terraform console -var environment=dev
rm backend_override.tf
```

A full plan without an AWS account runs against moto with a `providers_override.tf` pointing every
endpoint at it — only in a scratch copy, never in the repo. To try an unreleased module, point
its `source` at `../../terraform-root-module/modules/<name>` in that copy.

## How a config becomes infrastructure

- `config.tf` — `yamldecode` inside `try()` (a syntax error becomes a readable config error),
  `local.environments` (per-environment defaults), `local.sizes`, `local.services` (normalized)
  and `local.service_specs` (exact ECS inputs). `service_specs` must never reference a module
  output — the contract tests evaluate it without planning AWS.
- `validation.tf` — **layer 1**, `local.config_errors`: is the config well-formed?
- `policy.tf` — **layer 2**, `local.policy_errors`: is a well-formed config allowed in this
  environment? Both are enforced by `terraform_data.config` preconditions; layer 3 (can AWS build
  it) is the modules' own validation.
- `main.tf` — composition. Every `source` pins the same `?ref=`; CI fails if they differ.
- `ci/terraform.gitlab-ci.yml` — templates; `.gitlab-ci.yml` sets `TF_ENV` per job.
  `ENVIRONMENT` (Run pipeline) limits a run to one environment.

A new developer key needs: normalization in `config.tf`, the key in the unknown-key lists and a
check in `validation.tf`, wiring in `main.tf`, and a fixture + run in `tests/platform.tftest.hcl`.

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
  `http://<name>:8080` through Service Connect; more than one public service needs `dns.domain`.
- `config.yaml` is a public API — rename or remove a key only with a migration for every
  environment.
