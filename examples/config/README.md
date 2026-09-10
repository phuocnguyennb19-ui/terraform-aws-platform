# Example configs

Two files, because a base stack and an application stack are two Terraform
states — not two directories in one.

| File | Owns | Typical state key |
|---|---|---|
| `base.yaml` | VPC, security groups, KMS, IAM, ECR, ALB, ECS cluster, alarms | `platform/dev/base.tfstate` |
| `app.yaml` | one ECS service and its alarms | `platform/dev/api.tfstate` |

Neither file belongs in this repository in real use. They live in the
application repository next to its `backend.hcl`, and CI copies them into a
pinned clone of this one:

```bash
git clone --depth 1 --branch "$PLATFORM_REF" "$PLATFORM_REPO" tf
cp "config/$ENV/api.yaml" tf/config.yaml
cp "config/$ENV/api.backend.hcl" tf/backend.hcl

cd tf
terraform init -reconfigure -input=false -backend-config=backend.hcl
terraform plan  -input=false -var config_file=config.yaml -out=tfplan
terraform apply -input=false tfplan
```

`config_file` is resolved as `file("${path.cwd}/${var.config_file}")` — relative
to the directory Terraform **runs from**. Running from anywhere but the clone
root resolves it against the wrong directory and fails at plan.

## Order

`base.yaml` first. `app.yaml` finds it by name and tag, so the base stack's
outputs are what fill in the `existing:` block:

```bash
terraform output -json    # in the base stack
#   vpc_id, ecs_cluster_name, alb_target_group_arns, kms_key_arns
```

## The production floor

`global.environment: prod` is not just a name. It forces one NAT gateway per AZ,
RDS multi-AZ and deletion protection, a 30-day backup floor, a 90-day log floor,
a private EKS API endpoint, and a two-task floor on every ECS service. Those are
not expressible as "off" from a config file — see `local.hardened` in
`locals.tf` for the full list and why each one is there.
