# ===========================================================================
# LOOKUPS FOR INFRASTRUCTURE THIS STACK DOES NOT OWN
#
# An application stack disables vpc/alb/ecs_cluster and finds the base stack
# here. Every lookup is by NAME or TAG, never by a raw ID pasted into the config:
# an ID is opaque, environment specific, and silently wrong the moment a config
# is copied between environments. A tag lookup that finds nothing fails the plan,
# which is the behaviour you want.
#
# A data source with count = 0 is still validated against the provider schema, so
# every argument below falls back to something the schema accepts. None of those
# fallbacks is ever read: the count that guards them is false in exactly the
# cases where the config did not supply the real value.
# ===========================================================================

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# ---- VPC ------------------------------------------------------------------

data "aws_vpc" "existing" {
  count = local.lookup_vpc ? 1 : 0

  filter {
    name   = "tag:Name"
    values = [try(local.existing.vpc.name_tag, "unset")]
  }
}

data "aws_subnets" "private" {
  count = local.lookup_subnets ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [try(data.aws_vpc.existing[0].id, "vpc-unset")]
  }

  dynamic "filter" {
    for_each = try(local.existing.private_subnets.tags, {})

    content {
      name   = "tag:${filter.key}"
      values = [filter.value]
    }
  }
}

# ---- Security group -------------------------------------------------------
# Looked up by group name inside the VPC. Group names are unique per VPC, which
# is what makes this unambiguous without an ID.

data "aws_security_group" "ecs" {
  count = local.lookup_vpc && try(local.existing.ecs_security_group.name, null) != null ? 1 : 0

  vpc_id = try(data.aws_vpc.existing[0].id, null)
  name   = try(local.existing.ecs_security_group.name, "unset")
}

# ---- Load balancer --------------------------------------------------------

data "aws_lb" "existing" {
  count = local.lookup_alb ? 1 : 0

  name = try(local.existing.alb.name, "unset")
}

data "aws_lb_target_group" "existing" {
  for_each = local.lookup_alb ? try(local.existing.alb.target_group_names, {}) : {}

  name = each.value
}

# ---- ECS cluster ----------------------------------------------------------

data "aws_ecs_cluster" "existing" {
  count = local.lookup_cluster ? 1 : 0

  cluster_name = try(local.existing.ecs_cluster.name, "unset")
}

# ---- KMS ------------------------------------------------------------------
# By alias, which is the stable handle. A key ID changes when a key is replaced;
# the alias is moved to the new key and every consumer follows automatically.

data "aws_kms_key" "existing" {
  for_each = local.enabled.kms ? {} : try(local.existing.kms_aliases, {})

  key_id = each.value
}

# ===========================================================================
# RESOLVED FOUNDATION
#
# One name per thing, whether this stack built it or found it. Everything below
# main.tf reads these, so a module never has to know which of the two happened.
# ===========================================================================

locals {
  vpc_id = local.enabled.vpc ? module.vpc[0].vpc_id : try(data.aws_vpc.existing[0].id, null)

  vpc_cidr_block = local.enabled.vpc ? module.vpc[0].vpc_cidr_block : try(data.aws_vpc.existing[0].cidr_block, null)

  private_subnet_ids = local.enabled.vpc ? module.vpc[0].private_subnet_ids : try(data.aws_subnets.private[0].ids, [])

  public_subnet_ids = local.enabled.vpc ? module.vpc[0].public_subnet_ids : []

  database_subnet_group_name = local.enabled.vpc ? module.vpc[0].database_subnet_group_name : try(local.existing.database_subnet_group_name, null)

  elasticache_subnet_group_name = local.enabled.vpc ? module.vpc[0].elasticache_subnet_group_name : try(local.existing.elasticache_subnet_group_name, null)

  # KMS keys by purpose. An empty map is a valid answer: a stack that encrypts
  # nothing with a customer-managed key passes null everywhere below, and each
  # module falls back to the AWS-managed service key.
  kms_key_arns = local.enabled.kms ? module.kms[0].key_arns : { for k, v in data.aws_kms_key.existing : k => v.arn }

  ecs_security_group_ids = compact(
    local.enabled.security_groups
    ? [try(module.security_groups[0].ecs_sg_id, null)]
    : [try(data.aws_security_group.ecs[0].id, null)]
  )

  cluster_arn = local.enabled.ecs_cluster ? module.ecs_cluster[0].arn : try(data.aws_ecs_cluster.existing[0].arn, null)

  # Target groups this stack built, plus ones it found. A service names a key;
  # whether the ALB is in this state or the base stack's is not its problem.
  target_group_arns = merge(
    local.enabled.alb ? module.alb[0].target_group_arns : {},
    { for k, v in data.aws_lb_target_group.existing : k => v.arn },
  )
}
