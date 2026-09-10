# terraform-aws-platform

A reusable AWS Terraform platform built on a **Foundation → Shared Services → Workloads**
separation. Shared network and security infrastructure is created once per environment and
consumed by every workload through module outputs. No workload module creates a VPC, a
subnet, a NAT gateway, a route table or a security group.

```
                         Foundation
                             │
                            VPC
                             │
              ┌──────────────┼──────────────┐
              │              │              │
             EKS            EC2            RDS
```

Terraform **1.5.7+**, AWS provider **5.x**. Three environments — `dev`, `staging`, `prod` —
that share one identical root configuration and differ only in values.

---

## Contents

| | |
|---|---|
| [1. How the Foundation works](#1-how-the-foundation-works) | the layer everything else consumes |
| [2. How modules communicate](#2-how-modules-communicate) | outputs in, inputs out, no `depends_on` |
| [3. How EKS consumes VPC outputs](#3-how-eks-consumes-vpc-outputs) | |
| [4. How EC2 consumes VPC and SG outputs](#4-how-ec2-consumes-vpc-and-sg-outputs) | |
| [5. How RDS consumes database subnet and SG outputs](#5-how-rds-consumes-database-subnet-and-sg-outputs) | |
| [6. How ALB consumes public subnet and SG outputs](#6-how-alb-consumes-public-subnet-and-sg-outputs) | |
| [7. How to enable and disable workloads](#7-how-to-enable-and-disable-workloads) | |
| [8. How to deploy dev, staging and prod](#8-how-to-deploy-dev-staging-and-prod) | |
| [9. How Terraform state is managed](#9-how-terraform-state-is-managed) | |
| [10. How secrets are handled](#10-how-secrets-are-handled) | |
| [Repository layout](#repository-layout) · [Modules](#modules) · [Deployment scenarios](#deployment-scenarios) · [Production hardening floor](#production-hardening-floor) · [Validation and linting](#validation-and-linting) · [Known limitations](#known-limitations) | |

Architecture diagrams: [`docs/architecture.md`](docs/architecture.md).

---

## Quick start

```bash
# 1. State backend has to exist before the first apply. Prints the commands:
make bootstrap-state ENV=dev

# 2. Put the bucket and lock table you just created into environments/dev/backend.hcl,
#    then edit environments/dev/terraform.tfvars.

# 3. The normal loop. ENV is required on every target — there is no default.
make init  ENV=dev
make plan  ENV=dev      # writes environments/dev/tfplan-dev
make apply ENV=dev      # applies that saved plan, then deletes it

make output ENV=dev
```

Checks that need no AWS credentials:

```bash
make ci     # fmt-check + versions-check + env-drift + validate-all
```

---

## 1. How the Foundation works

The Foundation is the infrastructure that is **created once per environment and shared by
every workload in it**. It is three modules, composed in this order:

```
modules/kms              customer-managed keys, one per purpose
     │
modules/vpc              VPC, subnets, IGW, NAT, route tables, flow logs, endpoints
     │
modules/security-groups  one security group per tier, and the rules between them
     │
modules/iam              instance role, RDS monitoring role, permissions boundary
```

### The three-tier subnet layout

`modules/vpc` derives a full subnet plan from a single CIDR, so an environment supplies
`vpc_cidr = "10.10.0.0/16"` and gets:

| Tier | Size | Route to internet | What lives here |
|---|---|---|---|
| **public** | `/24` per AZ | IGW, both directions | ALB, NAT gateways — nothing else |
| **private (app)** | `/20` per AZ | outbound via NAT only | EKS nodes, EC2, Lambda ENIs |
| **private (data)** | `/24` per AZ | **none at all** | RDS, ElastiCache |

The application tier gets the `/20` blocks because it is the only tier whose address
consumption is unpredictable — the EKS VPC CNI burns one VPC address per pod. Public and
data subnets hold a countable number of ENIs.

The database tier has **no internet gateway route and no NAT route**. That is the structural
half of "never expose RDS to `0.0.0.0/0`": even a misconfigured security group cannot make
those subnets routable from outside. The security group is the second half.

Override the derivation with `public_subnet_cidrs` / `private_subnet_cidrs` /
`database_subnet_cidrs` when you need an exact plan.

### What else the Foundation carries

- **VPC flow logs** to CloudWatch, KMS-encrypted. The only record of who talked to what.
- **S3 gateway endpoint** — free, and it keeps S3 traffic off the NAT gateway.
- **Interface endpoints** — opt-in, for ECR/Logs/SSM when private subnets should not depend
  on NAT.
- **The default security group is stripped of every rule**, so nothing can accidentally
  attach to a permissive group.
- **EKS discovery tags** on the subnets (`kubernetes.io/role/elb`,
  `kubernetes.io/role/internal-elb`, `kubernetes.io/cluster/<name>`), added from a plain
  string list so the VPC never depends on the EKS module.

---

## 2. How modules communicate

**Foundation outputs become workload inputs. That is the entire mechanism.**

Terraform builds the dependency graph from the references themselves, so
`environments/*/main.tf` contains **no `depends_on` at all**. Writing one would only
serialise work that could otherwise run in parallel.

```hcl
module "vpc" {
  source     = "../../modules/vpc"
  name       = local.name_prefix
  cidr_block = var.vpc_cidr
}

module "security_groups" {
  source = "../../modules/security-groups"
  vpc_id = module.vpc.vpc_id          # ← creates the edge vpc → security_groups
}

module "rds" {
  source               = "../../modules/rds"
  db_subnet_group_name = module.vpc.database_subnet_group_name
  security_group_ids   = [module.security_groups.rds_sg_id]
}
```

Two cycles are broken deliberately, and both are worth knowing about:

- **`vpc` ↔ `security-groups`.** The VPC's interface endpoints need a security group, but
  the security-groups module needs `vpc_id`. The VPC module creates its own endpoint
  security group instead.
- **`alb` → `acm` → `route53` → `alb`.** The ALB needs a certificate, the certificate needs
  a zone to validate in, and the zone needs an alias record pointing at the ALB. The
  route53 module owns the zone only; the alias record is a bare `aws_route53_record` in the
  environment root.

### The module authoring contract

Every module follows the same shape, so a new one is predictable:

```
modules/<name>/
├── main.tf        resources, or a thin wrapper over a pinned upstream module
├── variables.tf   typed, described, validated
├── outputs.tf     the stable public interface
└── versions.tf    terraform >= 1.5.7, aws >= 5.80 < 6.0
```

No module declares a `provider` block. That is what lets one module serve every environment
and every region — the provider is configured once, in `environments/<env>/providers.tf`.

---

## 3. How EKS consumes VPC outputs

```hcl
module "eks" {
  source = "../../modules/eks"
  count  = var.enable_eks ? 1 : 0

  cluster_name       = local.eks_cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id               # ← Foundation
  subnet_ids = module.vpc.private_subnet_ids   # ← Foundation: PRIVATE, never public

  cluster_security_group_ids = [module.security_groups.eks_cluster_sg_id]
  node_security_group_ids    = [module.security_groups.eks_node_sg_id]

  kms_key_arn = module.kms.key_arns["eks"]     # ← Foundation: etcd secret encryption
}
```

Nodes go in **private** subnets. A node in a public subnet gets a public IP and is directly
reachable from the internet, which is not a cluster you want.

The module also provides:

- managed node groups with a launch template that **enforces IMDSv2 with hop limit 1**, so a
  compromised pod cannot mint credentials for the node's instance role — pods get AWS
  permissions through IRSA instead
- envelope encryption of Kubernetes Secrets in etcd with a customer-managed key (without it
  a Secret is base64, which is an encoding, not a protection)
- control plane logging including `audit`, retained and KMS-encrypted
- the four addons a cluster is not functional without — VPC CNI, CoreDNS, kube-proxy, EBS CSI
- `authentication_mode = "API_AND_CONFIG_MAP"` with access entries, so access is managed as
  AWS resources rather than by editing a ConfigMap that can lock everyone out
- IRSA roles, which live here rather than in the `iam` module because their trust policy has
  to name this cluster's OIDC provider

---

## 4. How EC2 consumes VPC and SG outputs

```hcl
module "ec2" {
  source = "../../modules/ec2"
  count  = var.enable_ec2 ? 1 : 0

  instances = {
    for k, i in var.ec2_instances : k => {
      # An environment names an index, not a subnet ID that does not exist yet.
      subnet_id = module.vpc.private_subnet_ids[i.subnet_index % length(module.vpc.private_subnet_ids)]
      ...
    }
  }

  security_group_ids   = [module.security_groups.ec2_sg_id]      # ← Foundation
  iam_instance_profile = module.iam.ec2_instance_profile_name    # ← Foundation
  kms_key_arn          = module.kms.key_arns["ebs"]              # ← Foundation
}
```

`associate_public_ip_address` is rejected by a validation block. Instances are reached
through **Session Manager**, which the instance role already allows — no key pair, no
inbound rule, no bastion, and every session recorded in CloudTrail:

```bash
make output ENV=dev            # prints ec2_session_manager_commands
aws ssm start-session --target i-0123456789abcdef0
```

---

## 5. How RDS consumes database subnet and SG outputs

```hcl
module "rds" {
  source = "../../modules/rds"
  count  = var.enable_rds ? 1 : 0

  db_subnet_group_name = module.vpc.database_subnet_group_name  # ← Foundation
  security_group_ids   = [module.security_groups.rds_sg_id]     # ← Foundation
  kms_key_arn          = module.kms.key_arns["rds"]             # ← Foundation
  monitoring_role_arn  = module.iam.rds_monitoring_role_arn     # ← Foundation
}
```

RDS is unreachable from the internet by **three independent mechanisms**, so no single
mistake exposes it:

1. the database subnets have **no IGW route and no NAT route**
2. `publicly_accessible` is hardcoded `false` in the module — it is not a variable
3. the RDS security group allows the database port **only from the application tiers**, by
   security-group reference, and carries **no egress rule at all**

Also on by default: storage encryption with a customer-managed key, enforced TLS
(`rds.force_ssl` / `require_secure_transport`), Enhanced Monitoring, Performance Insights,
log export to CloudWatch, and storage autoscaling.

---

## 6. How ALB consumes public subnet and SG outputs

```hcl
module "alb" {
  source = "../../modules/alb"
  count  = var.enable_alb ? 1 : 0

  vpc_id             = module.vpc.vpc_id                         # ← Foundation
  subnet_ids         = var.alb_internal ? module.vpc.private_subnet_ids
                                        : module.vpc.public_subnet_ids
  security_group_ids = [module.security_groups.alb_sg_id]        # ← Foundation
  certificate_arn    = one(module.acm[*].certificate_arn)        # ← Shared services
}
```

Public subnets make it internet-facing; private subnets plus `internal = true` make it
VPC-only. Either way the subnets came from the shared VPC.

Defaults: HTTP→HTTPS 301 redirect, a TLS 1.3 policy, `drop_invalid_header_fields` (forwarding
malformed headers is the basis of request smuggling), desync mitigation, and access logs to
a bucket the module creates with the right delivery policy, public access blocked and a
lifecycle rule.

Target registration is **not** this module's job — `create_attachment = false`. The AWS Load
Balancer Controller fills the group in EKS; an autoscaling group's `target_group_arns` fills
it for EC2.

### The request path

```
Internet ──▶ Route53 alias ──▶ ALB :443 (ACM cert, public subnets)
                                  │  alb_sg
                                  ▼
                          EKS pods / EC2 :8080 (private subnets)
                                  │  eks_node_sg / ec2_sg
                                  ▼
                          RDS :5432 · ElastiCache :6379 (data subnets)
                                     rds_sg / elasticache_sg
```

Every hop is a **security-group reference**, not a CIDR. A CIDR rule keeps allowing traffic
after the instance behind the address is replaced by something else; a group reference
follows membership, so scaling a node group never widens the boundary.

Raw CIDRs are accepted in exactly three places, all at the perimeter where there is no group
to reference: ALB ingress, bastion SSH, and the EKS public API endpoint. **The last two
reject `0.0.0.0/0` with a validation block.**

---

## 7. How to enable and disable workloads

Each workload is a `count`-guarded module driven by one boolean:

```hcl
enable_alb         = true
enable_eks         = true
enable_ec2         = false
enable_rds         = true
enable_elasticache = false
enable_lambda      = false
enable_ecr         = true
enable_route53     = false
enable_acm         = false   # requires enable_route53
```

The Foundation (`kms`, `vpc`, `security_groups`, `iam`, `cloudwatch`) is always created —
it is what makes the environment an environment.

Two consequences worth knowing:

- **Outputs use `one(module.x[*].y)`**, which yields `null` rather than erroring when a
  workload is off. That is what lets a single set of outputs describe every scenario from
  "VPC only" to the full stack.
- **`security-groups` follows the same toggles**, so disabling a tier removes both its group
  and the rules pointing at it, rather than leaving orphans behind.

Check what an environment actually has switched on:

```bash
make output ENV=dev     # includes enabled_workloads
```

---

## 8. How to deploy dev, staging and prod

### The environments are one configuration

`main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`, `backend.tf` and `versions.tf` are
**byte-identical** in all three environments. Only `terraform.tfvars` and `backend.hcl`
differ. This is enforced, not just intended:

```bash
make env-drift        # fails if the three roots have diverged
make versions-check   # fails if a versions.tf has drifted from the canonical one
```

Why it matters: staging is a rehearsal for prod. If staging is structurally different, a
procedure that works there proves nothing about prod.

### What the environments actually differ in

| | dev | staging | prod |
|---|---|---|---|
| CIDR | `10.10.0.0/16` | `10.20.0.0/16` | `10.30.0.0/16` |
| AZs | 2 | 3 | 3, pinned explicitly |
| NAT gateways | 1 (shared) | one per AZ | one per AZ (forced) |
| RDS | single-AZ, `t4g.medium` | **multi-AZ**, `t4g.large` | **multi-AZ**, `r6g.xlarge` |
| Backups | 3 days | 7 days | **30 days (floor)** |
| Deletion protection | off | off | **on (forced)** |
| EKS API endpoint | public, CIDR-restricted | public, CIDR-restricted | **private (forced)** |
| EKS capacity | spot only | on-demand + spot | on-demand floor + spot |
| Log retention | 7 days | 30 days | **90 days (floor)**, set to 365 |
| TLS | none (HTTP) | ACM | ACM |

### Deploying

```bash
make init  ENV=staging
make plan  ENV=staging     # read the plan
make apply ENV=staging     # applies the saved plan file, not a fresh one
```

`apply` deliberately requires a plan file written by `plan`. A bare `terraform apply` plans
and applies in one step, which means the thing that gets applied is not the thing anyone
read.

**A two-pass apply is needed the first time an environment enables both ACM and the ALB.**
The certificate must reach `ISSUED` before the HTTPS listener can reference it, and DNS
validation takes a few minutes. Re-run `make plan && make apply`; the second pass completes.

### Promotion

```
dev ──▶ staging ──▶ prod
```

Change `main.tf` once. It is the same file in all three, so a change lands in dev, is
rehearsed in staging, and reaches prod as the identical configuration with prod's values.
Container images promote by **digest** through a single shared ECR repository
(`ecr_use_name_prefix = false`) — an image built once and promoted is the same artifact,
where a per-environment rebuild is not.

---

## 9. How Terraform state is managed

**One S3 backend per environment, in its own bucket, with its own key and its own lock.**

`backend.tf` is deliberately empty:

```hcl
terraform {
  backend "s3" {}
}
```

Bucket, key, region and locking come from `environments/<env>/backend.hcl` at init time:

```hcl
bucket         = "my-terraform-state-prod"
key            = "platform/prod/terraform.tfstate"
region         = "ap-southeast-1"
encrypt        = true
dynamodb_table = "terraform-locks"
```

A committed bucket/key pair is how a dev apply ends up writing prod state. Keeping the
values in a per-environment file that `make init ENV=<env>` selects makes that mistake
require effort.

### Locking is not optional

Without a lock, two concurrent applies interleave their writes and corrupt the state file.
There is no recovery beyond restoring a previous version and reconciling by hand.

- **Terraform 1.5.7** (this repo's floor): a DynamoDB table with partition key `LockID`.
- **Terraform ≥ 1.10**: `use_lockfile = true` locks natively in S3 and the table can be
  dropped. Both lines are in every `backend.hcl`, one commented.

### Bootstrapping

The bucket and table are chicken-and-egg — they must exist before the first apply.
`make bootstrap-state ENV=dev` prints the commands, with versioning, KMS encryption and a
public access block.

### Treat state as sensitive

**State contains every resolved value in plaintext** — endpoints, generated identifiers,
anything a resource returns. That is why the bucket is encrypted, versioned and readable
only by the roles that need it, and why the CI workflow **does not upload plan files as
build artifacts**: a saved plan carries resolved values, and anyone who can download an
artifact could read them.

---

## 10. How secrets are handled

**The design goal is that there is nowhere to put a secret**, so the rule is not something
anyone has to remember.

| Secret | How it is handled | Where it is not |
|---|---|---|
| **Database master password** | `manage_master_user_password = true`. AWS generates and rotates it into Secrets Manager. | The RDS module has **no password variable**. There is nowhere to type one. |
| **Redis AUTH token** | Referenced by Secrets Manager **ARN**. | No literal token variable exists. |
| **TLS private keys** | Issued and renewed by ACM; the private key never leaves AWS. | Never in the repository. |
| **AWS credentials** | Assumed role (`assume_role_arn`) or OIDC in CI. | Never a Terraform variable. |
| **Application secrets** | Secrets Manager / Parameter Store, resolved by the app at runtime. | Not Lambda environment variables — those are visible to anyone with `lambda:GetFunctionConfiguration`. |

Reading the database password:

```bash
make output ENV=prod          # gives rds_master_user_secret_arn — an ARN, not a credential
```

Grant the application's IAM role `secretsmanager:GetSecretValue` **scoped to that ARN** and
let it resolve the secret at runtime. Verify the secret exists with
`aws secretsmanager describe-secret`, which confirms the KMS key and rotation status without
disclosing the value.

**Never resolve the plaintext into Terraform.** Anything Terraform reads is written to state.

### Encryption everywhere, with per-purpose keys

`modules/kms` creates one customer-managed key per purpose — `ebs`, `rds`, `logs`,
`secrets`, `eks`, `ecr` — each with rotation enabled and a key policy naming only the
service principals that need it.

One key per purpose rather than one key for everything, because a key policy is the only
place you can say "the RDS service may use this and nothing else", and a single shared key
collapses that distinction. Automatic rotation cannot be disabled through the module: a
validation block rejects it.

### Defence in depth

`.gitignore` excludes `*.tfvars` by default, re-including only the three committed,
secret-free environment files. `.pre-commit-config.yaml` runs `gitleaks` and
`detect-private-key`. Both are a last line of defence — the real protection is that no
module accepts a credential as an input.

---

## Repository layout

```
terraform-aws-platform/
├── modules/                    reusable, environment-agnostic, no provider blocks
│   ├── vpc/                    ── Foundation
│   ├── security-groups/
│   ├── iam/
│   ├── kms/
│   ├── alb/                    ── Shared services
│   ├── route53/
│   ├── acm/
│   ├── ecr/
│   ├── cloudwatch/
│   ├── eks/                    ── Workloads
│   ├── ec2/
│   ├── rds/
│   ├── elasticache/
│   └── lambda/
│
├── environments/
│   ├── dev/
│   │   ├── main.tf             ─┐
│   │   ├── variables.tf         │ byte-identical across all three
│   │   ├── outputs.tf           │ environments — `make env-drift`
│   │   ├── providers.tf         │ fails if they diverge
│   │   ├── backend.tf           │
│   │   ├── versions.tf         ─┘
│   │   ├── terraform.tfvars     ← environment values
│   │   └── backend.hcl          ← state location
│   ├── staging/
│   └── prod/
│
├── docs/architecture.md         diagrams and traffic flows
├── versions.tf                  canonical version constraints
├── terraform.tfvars.example
├── Makefile
├── .tflint.hcl · trivy.yaml · .checkov.yaml · .pre-commit-config.yaml
└── .github/workflows/terraform.yml
```

---

## Modules

Complex AWS resources wrap a pinned `terraform-aws-modules` release rather than being
reimplemented; simple ones use the provider directly. Wrapping keeps the platform's own
interface stable across upstream major versions — v8 and v9 of the ALB module have
materially different listener schemas, and callers should not have to care.

| Module | Implementation | Upstream pin |
|---|---|---|
| `vpc` | wrapper | `terraform-aws-modules/vpc/aws` **5.21.0** |
| `eks` | wrapper | `terraform-aws-modules/eks/aws` **20.37.2** |
| `alb` | wrapper + log bucket | `terraform-aws-modules/alb/aws` **9.17.0** |
| `rds` | wrapper | `terraform-aws-modules/rds/aws` **6.13.1** |
| `acm` | wrapper | `terraform-aws-modules/acm/aws` **5.2.0** |
| `ec2` | wrapper, `for_each` | `terraform-aws-modules/ec2-instance/aws` **5.8.0** |
| `lambda` | wrapper, `for_each` | `terraform-aws-modules/lambda/aws` **7.21.1** |
| `security-groups` | native | — |
| `iam` · `kms` · `route53` · `ecr` · `cloudwatch` · `elasticache` | native | — |

Those seven pins are the newest line that supports the **5.x AWS provider**. The 6.x
provider requires the next major of every one of them — a coordinated upgrade, not a bump.

---

## Deployment scenarios

**A — Base infrastructure.** Every toggle `false`. VPC, subnets, NAT, route tables, security
groups, KMS, IAM, the alarm topic. This is the substrate every other scenario builds on.

**B — EKS.** `enable_eks = true`. Cluster and managed node groups in the existing private
subnets.

**C — EC2.** `enable_ec2 = true` plus `ec2_instances`. Instances in the existing private
subnets, reached through Session Manager.

**D — RDS.** `enable_rds = true`. Database in the existing database subnets, password in
Secrets Manager.

**E — Complete application platform.** All toggles on:

```
Route53 ──▶ ALB ──▶ EKS / EC2 ──▶ RDS + ElastiCache
```

`environments/prod/terraform.tfvars` is a worked example of scenario E.

---

## Production hardening floor

When `environment == "prod"`, `main.tf` applies a floor that **a tfvars file cannot
weaken**:

| Forced in prod | Protects against |
|---|---|
| `single_nat_gateway = false` | an AZ failure removing egress for the whole VPC |
| RDS multi-AZ | an AZ failure becoming an outage rather than a failover |
| RDS deletion protection | a mistargeted destroy reaching the data |
| RDS final snapshot on delete | deletion being irreversible |
| Backup retention ≥ 30 days | corruption discovered in week three being unrecoverable |
| ALB deletion protection | the same, for the entry point |
| EKS API endpoint private | the control plane being one credential leak from the internet |
| Flow logs on, ≥ 90 days | an investigation with nothing to read |
| Log retention ≥ 90 days | the same |
| ElastiCache ≥ 2 nodes | a cache failure being a cold start under load |
| EC2 termination protection | an accidental terminate |

Raising a value above the floor still works; going below it is not expressible. A control
that can be switched off by editing a values file is a control that eventually gets switched
off in a hurry, by someone chasing an unrelated failure at 03:00.

---

## Validation and linting

```bash
make fmt            # terraform fmt -recursive
make fmt-check      # CI gate
make validate-all   # every environment
make env-drift      # the three roots have not diverged
make versions-check # version constraints are consistent
make lint           # tflint  — invalid instance types, unpinned sources, undocumented vars
make sec            # trivy config — the maintained successor to tfsec
make checkov        # checkov
make scan           # sec + checkov
make ci             # everything that needs no credentials
```

Install the optional tools with `brew install tflint trivy` and `pip install checkov`.
`pre-commit install` runs the same gates before the commit rather than after the push.

Every suppression in `trivy.yaml` and `.checkov.yaml` carries a written reason. They are
recorded decisions, not a way to reach a green run.

---

## Known limitations

Stated explicitly rather than discovered later:

1. **`terraform plan` has not been run against a live AWS account.** All three environments
   pass `terraform validate` and full variable validation; the plan reaches AWS credential
   validation and stops there. First-apply behaviour against real AWS is unverified.
2. **Two-pass apply on first use of ACM + ALB.** The certificate must be `ISSUED` before the
   HTTPS listener can reference it. Re-run plan and apply.
3. **`backend.hcl` files contain `REPLACE-ME` placeholders.** `make init` fails until a real
   bucket and lock table are filled in.
4. **`use_lockfile` needs Terraform ≥ 1.10.** On the 1.5.7 floor, state locking requires the
   DynamoDB table.
5. **ALB access log bucket policy is region-sensitive.** `use_elb_service_account_principal`
   defaults to `true`, which is correct for regions whose AZs launched before August 2022.
   In a newer region AWS assigns no ELB service account and the lookup fails — set it to
   `false`.
6. **ElastiCache AUTH token is read at plan time** from Secrets Manager and
   `ignore_changes` is set on it. Rotation is handled through the ElastiCache AUTH rotation
   strategy, not by Terraform.
7. **`checkov` and `tflint` were not executed** — neither is installed in the environment
   this was built in. Their configuration is written but unproven.
8. **No `terraform test` suite.** Validation is `validate` plus the linters. Module-level
   unit tests would be the next addition.
