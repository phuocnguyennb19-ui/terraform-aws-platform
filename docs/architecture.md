# Architecture

Diagrams and traffic flows for `terraform-aws-platform`. The narrative
explanation lives in [`../README.md`](../README.md).

---

## 1. Layers

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              FOUNDATION                                  │
│           created once per environment, consumed by everything           │
│                                                                          │
│   KMS ──── VPC ──── Subnets (public / private-app / private-data)        │
│             │        Internet Gateway · NAT Gateways · Route Tables      │
│             │        Flow Logs · VPC Endpoints                           │
│             │                                                            │
│             └──── Security Groups ──── IAM baseline                      │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │  outputs
┌───────────────────────────────▼──────────────────────────────────────────┐
│                           SHARED SERVICES                                │
│                                                                          │
│   Route53 ──▶ ACM ──▶ ALB          ECR          CloudWatch + SNS         │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │  outputs
┌───────────────────────────────▼──────────────────────────────────────────┐
│                              WORKLOADS                                   │
│                                                                          │
│      EKS          EC2          RDS          ElastiCache       Lambda     │
│       └────────────┴────────────┴────────────────┴───────────────┘       │
│              all consume the SAME vpc_id, subnets and SGs                │
└──────────────────────────────────────────────────────────────────────────┘
```

The rule the whole design turns on:

```
NEVER                              INSTEAD
─────                              ───────
EKS module ──▶ creates VPC                      Foundation
EC2 module ──▶ creates VPC                          │
RDS module ──▶ creates VPC                         VPC
                                                    │
three parallel network islands           ┌──────────┼──────────┐
that cannot reach each other            EKS        EC2        RDS
```

---

## 2. Network topology

One environment, three availability zones. `10.10.0.0/16` shown; staging uses
`10.20`, prod `10.30`.

```
                                  ┌─────────────┐
                                  │  Internet   │
                                  └──────┬──────┘
                                         │
                              ┌──────────▼──────────┐
                              │  Internet Gateway   │
                              └──────────┬──────────┘
┌────────────────────────────────────────┼─────────────────────────────────────┐
│ VPC 10.10.0.0/16                       │                                     │
│                                        │                                     │
│  ┌─────────────────────────────────────▼──────────────────────────────────┐  │
│  │ PUBLIC        10.10.240.0/24   10.10.241.0/24   10.10.242.0/24         │  │
│  │               ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │  │
│  │               │  ALB   NAT  │  │  ALB   NAT  │  │  ALB   NAT  │        │  │
│  │               └───────┬─────┘  └───────┬─────┘  └───────┬─────┘        │  │
│  └───────────────────────┼────────────────┼────────────────┼──────────────┘  │
│                          │ egress         │ egress         │ egress          │
│  ┌───────────────────────▼────────────────▼────────────────▼──────────────┐  │
│  │ PRIVATE — APP  10.10.0.0/20    10.10.16.0/20    10.10.32.0/20          │  │
│  │                ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │  │
│  │                │  EKS nodes  │  │  EKS nodes  │  │  EKS nodes  │       │  │
│  │                │  EC2 · λ    │  │  EC2 · λ    │  │  EC2 · λ    │       │  │
│  │                └───────┬─────┘  └───────┬─────┘  └───────┬─────┘       │  │
│  └────────────────────────┼────────────────┼────────────────┼─────────────┘  │
│                           │                │                │                │
│  ┌────────────────────────▼────────────────▼────────────────▼─────────────┐  │
│  │ PRIVATE — DATA  10.10.250.0/24  10.10.251.0/24  10.10.252.0/24         │  │
│  │                 ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │  │
│  │                 │ RDS primary │  │ RDS standby │  │ ElastiCache │      │  │
│  │                 └─────────────┘  └─────────────┘  └─────────────┘      │  │
│  │                                                                        │  │
│  │  NO internet gateway route.  NO NAT route.  Unreachable from outside   │  │
│  │  regardless of what any security group says.                          │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  AZ-a                    AZ-b                    AZ-c                        │
└──────────────────────────────────────────────────────────────────────────────┘
```

Why the application tier gets the `/20` blocks: it is the only tier whose address
consumption is unpredictable. The EKS VPC CNI assigns one **VPC address per pod**, so a
node running 50 pods consumes 50 addresses. Public and data subnets hold a countable number
of ENIs, so `/24` is generous there.

Addresses `10.10.48.0` – `10.10.239.255` are left free for tiers added later.

---

## 3. Security group architecture

Every edge below is a **security group reference**, never a CIDR.

```
                        ┌──────────────┐
                        │   Internet   │
                        └──────┬───────┘
                               │  :80 → 301 → :443
                        ┌──────▼───────┐
                        │   alb_sg     │  ingress 80/443 from alb_ingress_cidrs
                        │              │  egress  → VPC CIDR only
                        └──┬────────┬──┘
              :8080        │        │        :8080 · :30000-32767
        ┌──────────────────┘        └──────────────────┐
        │                                              │
┌───────▼────────┐                          ┌──────────▼──────────┐
│    ec2_sg      │                          │    eks_node_sg      │◀──┐
│                │                          │                     │───┘ node↔node
│ ← :22 bastion  │                          │ ← :10250 :443 from  │     (CNI, CoreDNS)
│                │                          │        eks_cluster  │
│ egress → any   │                          │ egress → any        │
└───────┬────────┘                          └──────────┬──────────┘
        │                                              │
        │            ┌──────────────────┐              │
        │            │  eks_cluster_sg  │◀─────────────┘  :443
        │            │  egress → any    │
        │            └──────────────────┘
        │                                              │
        │  :5432                                       │  :5432 / :6379
        └──────────────────┬───────────────────────────┘
                           │
             ┌─────────────▼──────────────┐
             │   rds_sg  ·  elasticache_sg│
             │                            │
             │   NO EGRESS RULE AT ALL    │
             │   (a group with zero       │
             │    egress rules denies      │
             │    all outbound)           │
             └────────────────────────────┘
```

**Raw CIDRs are accepted in exactly three places**, all at the perimeter where there is no
group to reference:

| Where | Default | Guard |
|---|---|---|
| `alb_ingress_cidrs` | `0.0.0.0/0` | correct for an internet-facing ALB |
| `bastion_allowed_cidrs` | `[]` | **validation rejects `0.0.0.0/0`** |
| `eks_public_api_allowed_cidrs` | `[]` | **validation rejects `0.0.0.0/0`**, and prod forces the endpoint private |

Rules are separate `aws_vpc_security_group_ingress_rule` / `egress_rule` resources rather
than inline blocks. Inline blocks are authoritative over the whole group, so two modules
touching one group silently delete each other's rules.

---

## 4. Module dependency graph

Edges are **output → input** references. There is no `depends_on` anywhere in the
environment roots.

```
                        ┌─────────┐
                        │   kms   │  ebs · rds · logs · secrets · eks · ecr
                        └────┬────┘
                             │ key_arns
              ┌──────────────┼──────────────────────────────┐
              │              │                              │
         ┌────▼────┐    ┌────▼─────┐                  ┌─────▼──────┐
         │   vpc   │    │cloudwatch│                  │    ecr     │
         └────┬────┘    └────┬─────┘                  └─────┬──────┘
              │              │ sns_topic_arn                │ repository_arns
              │ vpc_id       │                              │
       ┌──────▼────────┐     │                        ┌─────▼──────┐
       │security_groups│     │                        │    iam     │
       └──────┬────────┘     │                        └─────┬──────┘
              │              │                              │ instance_profile
              │              │                              │ rds_monitoring_role
   ┌──────────┼──────────────┼──────────────────────────────┼──────────┐
   │          │              │                              │          │
┌──▼───┐  ┌───▼───┐  ┌───────▼──────┐  ┌──────────┐  ┌──────▼───┐  ┌───▼────┐
│ eks  │  │  ec2  │  │ elasticache  │  │  lambda  │  │   rds    │  │  alb   │
└──────┘  └───────┘  └──────────────┘  └──────────┘  └──────────┘  └───┬────┘
                                                                       │ dns_name
   ┌─────────┐        ┌─────────┐                              ┌───────▼────────┐
   │ route53 │───────▶│   acm   │─────────────────────────────▶│ route53_record │
   │ (zone)  │zone_id │  cert   │ certificate_arn ──▶ alb      │    (alias)     │
   └─────────┘        └─────────┘                              └────────────────┘
```

### The two cycles that had to be broken

**`vpc` ↔ `security-groups`.** The VPC's interface endpoints need a security group; the
security-groups module needs `vpc_id`. Resolved by having the VPC module create its own
endpoint security group.

**`alb` → `acm` → `route53` → `alb`.** The ALB needs a certificate; the certificate needs a
zone to write validation records into; the zone needs an alias record pointing at the ALB.
Resolved by splitting *owning the zone* from *writing one record into it* — the route53
module owns the zone, and the alias record is a bare `aws_route53_record` in the
environment root.

---

## 5. Request path, end to end

```
  ① Client                          https://api.example.com
        │
        ▼
  ② Route53                         A/alias ──▶ ALB (evaluate_target_health)
        │
        ▼
  ③ ALB :443                        ACM certificate · TLS 1.3 policy
        │                            :80 answers a 301 and nothing else
        │                            access logs ──▶ S3
        ▼
  ④ Target group                    target_type "ip" for EKS · "instance" for EC2
        │                            health check ──▶ /healthz
        ▼
  ⑤ Pod / instance :8080            private subnet, no public IP
        │                            IMDSv2 required, hop limit 1
        │                            AWS permissions via IRSA / instance role
        ├──────────────▶ ⑥ RDS :5432          TLS enforced · encrypted at rest
        │                                      password in Secrets Manager
        └──────────────▶ ⑦ ElastiCache :6379  TLS in transit · encrypted at rest
                                               AUTH token by secret ARN
```

Return path for anything the workload initiates outbound:

```
  Pod / instance ──▶ NAT gateway (its own AZ) ──▶ Internet Gateway ──▶ Internet
                 ──▶ S3 / DynamoDB gateway endpoint          (no NAT, no charge)
                 ──▶ ECR / Logs / SSM interface endpoint     (opt-in, stays in-VPC)
```

---

## 6. Deployment scenarios

```
A · BASE                B · EKS                 C · EC2                D · RDS
──────────              ───────                 ───────                ───────
VPC                     Foundation              Foundation             Foundation
├─ Subnets                  │                       │                      │
├─ NAT                      └─ EKS                   └─ Private subnet      └─ Database
├─ Routes                      ├─ Control plane          │                     subnets
├─ Security groups             └─ Managed node           └─ EC2                   │
├─ KMS                            groups                                          └─ RDS
└─ IAM

all toggles false       enable_eks = true       enable_ec2 = true      enable_rds = true


E · COMPLETE APPLICATION PLATFORM
─────────────────────────────────
        Route53
           │
           ▼
          ALB  ◀── ACM
           │
     ┌─────┴─────┐
     ▼           ▼
    EKS         EC2
     │           │
     └─────┬─────┘
           ▼
    RDS + ElastiCache

all toggles true — see environments/prod/terraform.tfvars
```

---

## 7. Environment topology

```
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│      DEV      │   │    STAGING    │   │     PROD      │
│  10.10.0.0/16 │   │  10.20.0.0/16 │   │  10.30.0.0/16 │
│               │   │               │   │               │
│  2 AZ         │   │  3 AZ         │   │  3 AZ, pinned │
│  1 NAT        │   │  3 NAT        │   │  3 NAT        │
│  single-AZ DB │   │  multi-AZ DB  │   │  multi-AZ DB  │
│  spot only    │   │  on-dem+spot  │   │  on-dem+spot  │
│  public API   │   │  public API   │   │  PRIVATE API  │
│  3d backups   │   │  7d backups   │   │  30d backups  │
│  HTTP         │   │  ACM TLS      │   │  ACM TLS      │
└───────┬───────┘   └───────┬───────┘   └───────┬───────┘
        │                   │                   │
        └───────────────────┴───────────────────┘
                            │
              IDENTICAL main.tf / variables.tf /
              outputs.tf / providers.tf / backend.tf /
              versions.tf  —  enforced by `make env-drift`

              Separate state bucket, key and lock per
              environment. No shared state, ever.
```

Non-overlapping CIDRs are not cosmetic: overlapping ranges make VPC peering and Transit
Gateway attachment impossible later, and the only fix is re-addressing a live environment.

---

## 8. Where the secrets are not

```
       Terraform source ──┐
       terraform.tfvars ──┤──▶  contains NO credential, by construction
       Terraform state  ──┘      (there is no password variable to set)

                    ┌──────────────────────────────┐
   RDS ────────────▶│  AWS Secrets Manager         │
   (AWS generates   │  · master password           │
    and rotates)    │  · rotated by AWS            │
                    │                              │
   ElastiCache ────▶│  · AUTH token                │◀── referenced by ARN only
                    └──────────────┬───────────────┘
                                   │ secretsmanager:GetSecretValue
                                   │ scoped to one ARN
                                   ▼
                          Application at runtime

                    ┌──────────────────────────────┐
   ALB ────────────▶│  ACM                         │
                    │  · certificate + private key │
                    │  · private key never leaves  │
                    │    AWS, renewed automatically│
                    └──────────────────────────────┘
```

Terraform holds **ARNs**, never values. An ARN is an address; reading what is behind it
would write the plaintext into state, which is the whole thing this arrangement avoids.
