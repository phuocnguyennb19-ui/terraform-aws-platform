# ===========================================================================
# LIBRARY COMPOSITION — config.yaml mapped onto modules
#
# Every block below is gated by its own `enabled:` flag in the config, so one
# root serves both shapes of stack:
#
#   base config      — kms, vpc, security_groups, iam, cloudwatch, ecr, alb,
#                      ecs_cluster enabled. Owns the shared infrastructure.
#   application config — all of the above disabled, `existing:` naming the base
#                      stack's resources, `ecs_services:` describing the app.
#
# Dependency order is expressed entirely through module outputs feeding module
# inputs. There is not one depends_on in this file: Terraform derives the graph
# from the references themselves, and an explicit depends_on would only
# serialise things that could otherwise run in parallel.
#
#   kms ──┐
#         ├──▶ vpc ──┬──▶ security_groups ──┬──▶ alb ──▶ route53 (alias record)
#   iam ──┘          │                      ├──▶ ecs_cluster ──▶ ecs_service
#                    │                      ├──▶ eks
#                    │                      ├──▶ ec2
#                    │                      ├──▶ rds
#                    │                      ├──▶ elasticache
#                    │                      └──▶ lambda
#                    │
#   route53 (zone) ──▶ acm ──▶ alb ──▶ aws_route53_record.app (alias)
#
# The alias record is a bare resource rather than an input to the route53 module
# on purpose. Routing it through the module would make route53 depend on alb,
# while alb already depends on acm which depends on route53's zone id — a cycle
# Terraform rejects outright. Splitting "own the zone" from "write one record
# into it" is what breaks it.
# ===========================================================================

locals {
  # The default key set. One key per purpose rather than one key for everything:
  # a key policy is the only place you can say "the RDS service may use this and
  # nothing else", and a single shared key collapses that distinction.
  default_kms_keys = {
    ebs = {
      description        = "EBS volume encryption for ${local.name_prefix}"
      service_principals = ["ec2.amazonaws.com"]
    }
    rds = {
      description        = "RDS storage, snapshot and Performance Insights encryption for ${local.name_prefix}"
      service_principals = ["rds.amazonaws.com", "monitoring.rds.amazonaws.com"]
    }
    logs = {
      description        = "CloudWatch Logs encryption for ${local.name_prefix}"
      service_principals = ["logs.${local.region}.amazonaws.com"]
    }
    secrets = {
      description        = "Secrets Manager and SNS encryption for ${local.name_prefix}"
      service_principals = ["secretsmanager.amazonaws.com", "sns.amazonaws.com", "cloudwatch.amazonaws.com"]
    }
    eks = {
      description        = "EKS envelope encryption for Kubernetes Secrets in ${local.name_prefix}"
      service_principals = ["eks.amazonaws.com"]
    }
    ecr = {
      description        = "ECR image layer encryption for ${local.name_prefix}"
      service_principals = ["ecr.amazonaws.com"]
    }
  }

  # Null when the key does not exist in this stack, which is what every module
  # takes as "use the AWS-managed service key".
  kms = {
    ebs     = try(local.kms_key_arns["ebs"], null)
    rds     = try(local.kms_key_arns["rds"], null)
    logs    = try(local.kms_key_arns["logs"], null)
    secrets = try(local.kms_key_arns["secrets"], null)
    eks     = try(local.kms_key_arns["eks"], null)
    ecr     = try(local.kms_key_arns["ecr"], null)
  }
}

# ===========================================================================
# FOUNDATION
# ===========================================================================

module "kms" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/kms?ref=v1.0.0"
  count  = local.enabled.kms ? 1 : 0

  name = local.name_prefix
  tags = local.common_tags

  keys = try(local.config.kms.keys, local.default_kms_keys)
}

module "vpc" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/vpc?ref=v1.0.0"
  count  = local.enabled.vpc ? 1 : 0

  name       = local.name_prefix
  cidr_block = local.config.vpc.cidr
  az_count   = try(local.config.vpc.az_count, 3)
  azs        = try(local.config.vpc.azs, null)

  public_subnet_cidrs   = try(local.config.vpc.public_subnet_cidrs, null)
  private_subnet_cidrs  = try(local.config.vpc.private_subnet_cidrs, null)
  database_subnet_cidrs = try(local.config.vpc.database_subnet_cidrs, null)

  enable_nat_gateway     = try(local.config.vpc.enable_nat_gateway, true)
  single_nat_gateway     = local.hardened.single_nat_gateway
  one_nat_gateway_per_az = !local.hardened.single_nat_gateway

  enable_flow_logs        = local.hardened.enable_flow_logs
  flow_log_retention_days = local.hardened.flow_log_retention_days
  flow_log_kms_key_arn    = local.kms.logs

  create_database_subnet_group    = try(local.config.vpc.create_database_subnet_group, true)
  create_elasticache_subnet_group = local.enabled.elasticache

  enable_s3_gateway_endpoint       = try(local.config.vpc.enable_s3_gateway_endpoint, true)
  enable_dynamodb_gateway_endpoint = try(local.config.vpc.enable_dynamodb_gateway_endpoint, false)

  # No security group is passed: the vpc module creates its own for the
  # endpoints. Taking one from the security-groups module would be a cycle,
  # since that module needs vpc_id from here.
  interface_endpoints = try(local.config.vpc.interface_endpoints, [])

  eks_cluster_names = local.eks_cluster_names

  tags = local.common_tags
}

# Every workload takes its security group from here rather than creating one,
# so the tier-to-tier rules live in a single readable place.
module "security_groups" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/security-groups?ref=v1.0.0"
  count  = local.enabled.security_groups ? 1 : 0

  name           = local.name_prefix
  vpc_id         = local.vpc_id
  vpc_cidr_block = local.vpc_cidr_block

  create_alb_sg         = local.enabled.alb
  create_ecs_sg         = local.enabled.ecs_cluster || length(local.ecs_services) > 0
  create_eks_sg         = local.enabled.eks
  create_ec2_sg         = local.enabled.ec2
  create_rds_sg         = local.enabled.rds
  create_elasticache_sg = local.enabled.elasticache
  create_lambda_sg      = local.enabled.lambda
  create_bastion_sg     = try(local.config.security_groups.create_bastion_sg, false)

  application_port = local.application_port
  database_port    = local.rds_port
  cache_port       = local.cache_port

  alb_ingress_cidrs            = try(local.config.alb.ingress_cidrs, ["0.0.0.0/0"])
  bastion_allowed_cidrs        = try(local.config.security_groups.bastion_allowed_cidrs, [])
  eks_public_api_allowed_cidrs = local.hardened.eks_public_api_access ? try(local.config.eks.public_api_cidrs, []) : []

  additional_ingress_rules = try(local.config.security_groups.additional_ingress_rules, {})

  tags = local.common_tags
}

module "iam" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/iam?ref=v1.0.0"
  count  = local.enabled.iam ? 1 : 0

  name                     = local.name_prefix
  permissions_boundary_arn = try(local.config.iam.permissions_boundary_arn, null)

  create_ec2_instance_role   = local.enabled.ec2
  create_rds_monitoring_role = local.enabled.rds

  # Iterating the module rather than indexing it: module.ecr[0] is an error when
  # ecr is disabled, and a conditional does not reliably guard against it.
  ec2_ecr_pull_repository_arns = flatten([for m in module.ecr : values(m.repository_arns)])
  ec2_kms_key_arns             = compact([local.kms.ebs])

  additional_roles = try(local.config.iam.additional_roles, {})

  tags = local.common_tags
}

# ===========================================================================
# SHARED SERVICES
# ===========================================================================

module "cloudwatch" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/cloudwatch?ref=v1.0.0"
  count  = local.enabled.cloudwatch ? 1 : 0

  name = local.name_prefix

  create_sns_topic  = true
  sns_kms_key_arn   = local.kms.secrets
  sns_subscriptions = try(local.config.cloudwatch.alarm_subscriptions, {})

  default_log_kms_key_arn = local.kms.logs

  log_groups = {
    application = {
      name              = "/${local.project}/${local.environment}/application"
      retention_in_days = local.hardened.log_retention_days
    }
  }

  # Filtered with for-expressions, not conditionals. Terraform requires both
  # branches of a ternary to have the same object type, and "the RDS alarms" and
  # "{}" never will — a for-expression with an `if` sidesteps that entirely.
  metric_alarms = merge(
    { for k, v in local.rds_alarms : k => v if local.enabled.rds },
    { for k, v in local.alb_alarms : k => v if local.enabled.alb },
    { for k, v in local.cache_alarms : k => v if local.enabled.elasticache },
    local.ecs_alarms,
  )

  create_dashboard = try(local.config.cloudwatch.create_dashboard, false)

  tags = local.common_tags
}

module "ecr" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/ecr?ref=v1.0.0"
  count  = local.enabled.ecr ? 1 : 0

  name            = local.name_prefix
  use_name_prefix = try(local.config.ecr.use_name_prefix, false)
  repositories    = try(local.config.ecr.repositories, {})
  kms_key_arn     = local.kms.ecr

  tags = local.common_tags
}

# Composed before ACM: the certificate's DNS validation records are written into
# this zone, so the zone ID has to exist first.
module "route53" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/route53?ref=v1.0.0"
  count  = local.enabled.route53 ? 1 : 0

  zone_name   = local.domain_name
  create_zone = try(local.config.route53.create_zone, false)

  # Records are written below, not here — see the note in the header about the
  # alb/acm/route53 cycle.
  records = try(local.config.route53.records, {})

  tags = local.common_tags
}

# An alias rather than a CNAME: it resolves at no charge, follows the load
# balancer's addresses automatically, and is the only record type that can sit
# on a zone apex.
resource "aws_route53_record" "app" {
  count = local.enabled.route53 && local.enabled.alb ? 1 : 0

  zone_id = module.route53[0].zone_id
  name    = local.app_fqdn
  type    = "A"

  alias {
    name                   = module.alb[0].dns_name
    zone_id                = module.alb[0].zone_id
    evaluate_target_health = true
  }
}

module "acm" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/acm?ref=v1.0.0"
  count  = local.enabled.acm && local.enabled.route53 ? 1 : 0

  domain_name               = local.app_fqdn
  subject_alternative_names = try(local.config.acm.subject_alternative_names, [])
  zone_id                   = one(module.route53[*].zone_id)

  tags = local.common_tags
}

module "alb" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/alb?ref=v1.0.0"
  count  = local.enabled.alb ? 1 : 0

  name   = substr("${local.name_prefix}-alb", 0, 32)
  vpc_id = local.vpc_id

  subnet_ids         = try(local.config.alb.internal, false) ? local.private_subnet_ids : local.public_subnet_ids
  security_group_ids = [module.security_groups[0].alb_sg_id]
  internal           = try(local.config.alb.internal, false)

  certificate_arn = one(module.acm[*].certificate_arn)

  # target_type follows the compute in this stack: Fargate and the AWS Load
  # Balancer Controller both register by IP, only an EC2 autoscaling group
  # registers by instance.
  target_groups = {
    for k, t in try(local.config.alb.target_groups, { app = {} }) : k => {
      port             = try(t.port, local.application_port)
      protocol         = try(t.protocol, "HTTP")
      target_type      = try(t.target_type, local.target_group_type)
      protocol_version = try(t.protocol_version, "HTTP1")

      health_check = {
        path                = try(t.health_check_path, "/healthz")
        matcher             = try(t.health_check_matcher, "200")
        interval            = try(t.health_check_interval, 15)
        timeout             = try(t.health_check_timeout, 5)
        healthy_threshold   = try(t.healthy_threshold, 2)
        unhealthy_threshold = try(t.unhealthy_threshold, 3)
      }
    }
  }

  default_target_group_key = try(local.config.alb.default_target_group_key, "app")
  listener_rules           = try(local.config.alb.listener_rules, {})

  enable_deletion_protection = local.hardened.alb_deletion_protection
  enable_access_logs         = try(local.config.alb.enable_access_logs, true)
  access_logs_retention_days = try(local.config.alb.access_logs_retention_days, 90)
  idle_timeout               = try(local.config.alb.idle_timeout, 60)

  tags = local.common_tags
}

# ===========================================================================
# WORKLOADS
#
# Every one of these takes vpc_id / subnet IDs / security group IDs as inputs.
# None of them creates network infrastructure.
# ===========================================================================

# ---- ECS ------------------------------------------------------------------
# The cluster is a scheduling boundary shared by every service in the
# environment; the services are separate module instances so that adding one
# does not touch the others' task definitions.

module "ecs_cluster" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/ecs-cluster?ref=v1.0.0"
  count  = local.enabled.ecs_cluster ? 1 : 0

  cluster_name = "${local.name_prefix}-ecs"

  container_insights = try(local.config.ecs_cluster.container_insights, true)

  fargate_base        = try(local.config.ecs_cluster.fargate_base, 1)
  fargate_weight      = try(local.config.ecs_cluster.fargate_weight, 1)
  fargate_spot_weight = try(local.config.ecs_cluster.fargate_spot_weight, 0)

  log_retention_days          = local.hardened.log_retention_days
  log_kms_key_arn             = local.kms.logs
  execute_command_kms_key_arn = local.kms.secrets

  service_connect_namespace = try(local.config.ecs_cluster.service_connect_namespace, null)

  tags = local.common_tags
}

module "ecs_service" {
  source   = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/ecs-service?ref=v1.0.0"
  for_each = local.ecs_services

  name        = "${local.name_prefix}-${each.key}"
  cluster_arn = local.cluster_arn

  subnet_ids         = local.private_subnet_ids
  security_group_ids = local.ecs_security_group_ids

  # ---- Task definition ----------------------------------------------------
  cpu                  = try(each.value.cpu, 512)
  memory               = try(each.value.memory, 1024)
  cpu_architecture     = try(each.value.cpu_architecture, "X86_64")
  ephemeral_storage_gb = try(each.value.ephemeral_storage_gb, null)

  containers = each.value.containers
  volumes    = try(each.value.volumes, {})

  log_retention_days = local.hardened.log_retention_days
  log_kms_key_arn    = local.kms.logs

  # ---- Service ------------------------------------------------------------
  desired_count = max(try(each.value.desired_count, 2), local.hardened.ecs_min_tasks)

  deployment_minimum_healthy_percent = try(each.value.deployment_minimum_healthy_percent, 100)
  deployment_maximum_percent         = try(each.value.deployment_maximum_percent, 200)
  enable_circuit_breaker             = try(each.value.enable_circuit_breaker, true)
  enable_execute_command             = try(each.value.enable_execute_command, true)
  wait_for_steady_state              = try(each.value.wait_for_steady_state, true)
  platform_version                   = try(each.value.platform_version, "LATEST")
  capacity_provider_strategy         = try(each.value.capacity_provider_strategy, {})

  # ---- Load balancer ------------------------------------------------------
  # target_group_key indexes local.target_group_arns, which holds the groups
  # this stack built AND the ones it looked up from the base stack. A service
  # names a key; where the ALB lives is not its problem.
  target_group_arn                  = try(local.target_group_arns[each.value.target_group_key], null)
  load_balancer_container_name      = try(each.value.load_balancer_container, null)
  load_balancer_container_port      = try(each.value.load_balancer_port, null)
  health_check_grace_period_seconds = try(each.value.health_check_grace_period_seconds, 60)

  # ---- Autoscaling --------------------------------------------------------
  enable_autoscaling         = try(each.value.autoscaling.enabled, true)
  autoscaling_min_capacity   = max(try(each.value.autoscaling.min, 2), local.hardened.ecs_min_tasks)
  autoscaling_max_capacity   = try(each.value.autoscaling.max, 10)
  autoscaling_cpu_target     = try(each.value.autoscaling.cpu_target, 70)
  autoscaling_memory_target  = try(each.value.autoscaling.memory_target, 70)
  autoscaling_policies_extra = try(each.value.autoscaling.policies, {})

  # ---- IAM ----------------------------------------------------------------
  task_exec_iam_role_arn    = try(each.value.task_exec_iam_role_arn, null)
  task_exec_secret_arns     = try(each.value.task_exec_secret_arns, [])
  task_exec_ssm_param_arns  = try(each.value.task_exec_ssm_param_arns, [])
  tasks_iam_role_arn        = try(each.value.tasks_iam_role_arn, null)
  tasks_iam_role_policies   = try(each.value.tasks_iam_role_policies, {})
  tasks_iam_role_statements = try(each.value.tasks_iam_role_statements, [])
  permissions_boundary_arn  = try(local.config.iam.permissions_boundary_arn, null)

  tags = merge(local.common_tags, { Service = each.key })
}

# ---- EKS ------------------------------------------------------------------

module "eks" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/eks?ref=v1.0.0"
  count  = local.enabled.eks ? 1 : 0

  cluster_name       = local.eks_cluster_name
  kubernetes_version = try(local.config.eks.kubernetes_version, "1.31")

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids

  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = local.hardened.eks_public_api_access
  cluster_endpoint_public_access_cidrs = try(local.config.eks.public_api_cidrs, [])

  cluster_security_group_ids = [module.security_groups[0].eks_cluster_sg_id]
  node_security_group_ids    = [module.security_groups[0].eks_node_sg_id]

  node_groups = try(local.config.eks.node_groups, {})

  kms_key_arn                = local.kms.eks
  cluster_log_kms_key_arn    = local.kms.logs
  cluster_log_retention_days = local.hardened.log_retention_days

  irsa_roles     = try(local.config.eks.irsa_roles, {})
  access_entries = try(local.config.eks.access_entries, {})

  tags = local.common_tags
}

# ---- EC2 ------------------------------------------------------------------

module "ec2" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/ec2?ref=v1.0.0"
  count  = local.enabled.ec2 ? 1 : 0

  name = local.name_prefix

  instances = {
    # Resolved from the foundation. A config names an index, not a subnet ID
    # that does not exist until the VPC is applied.
    for k, i in try(local.config.ec2.instances, {}) : k => {
      subnet_id = local.private_subnet_ids[
        try(i.subnet_index, 0) % length(local.private_subnet_ids)
      ]
      instance_type    = try(i.instance_type, "t3.medium")
      ami_id           = try(i.ami_id, null)
      root_volume_size = try(i.root_volume_size, 30)
      user_data        = try(i.user_data, null)
      tags             = try(i.tags, {})
    }
  }

  security_group_ids   = [module.security_groups[0].ec2_sg_id]
  iam_instance_profile = module.iam[0].ec2_instance_profile_name
  kms_key_arn          = local.kms.ebs

  enable_termination_protection_default = local.hardened.ec2_termination_protection

  tags = local.common_tags
}

# ---- RDS ------------------------------------------------------------------

module "rds" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/rds?ref=v1.0.0"
  count  = local.enabled.rds ? 1 : 0

  identifier = local.rds_identifier

  engine               = local.rds_engine
  engine_version       = try(local.config.rds.engine_version, "16.4")
  family               = try(local.config.rds.family, "postgres16")
  major_engine_version = try(local.config.rds.major_engine_version, "16")
  instance_class       = try(local.config.rds.instance_class, "db.t4g.medium")

  db_subnet_group_name = local.database_subnet_group_name
  security_group_ids   = [module.security_groups[0].rds_sg_id]

  allocated_storage     = try(local.config.rds.allocated_storage, 50)
  max_allocated_storage = try(local.config.rds.max_allocated_storage, 200)
  kms_key_arn           = local.kms.rds

  db_name  = try(local.config.rds.database_name, "appdb")
  username = try(local.config.rds.username, "dbadmin")
  # No password argument exists. AWS generates it into Secrets Manager.
  master_user_secret_kms_key_arn = local.kms.secrets

  multi_az                = local.hardened.rds_multi_az
  backup_retention_period = local.hardened.rds_backup_retention_period
  deletion_protection     = local.hardened.rds_deletion_protection
  skip_final_snapshot     = local.hardened.rds_skip_final_snapshot
  apply_immediately       = local.hardened.rds_apply_immediately

  monitoring_role_arn              = module.iam[0].rds_monitoring_role_arn
  performance_insights_kms_key_arn = local.kms.rds

  cloudwatch_log_group_retention_in_days = local.hardened.log_retention_days

  tags = local.common_tags
}

# ---- ElastiCache ----------------------------------------------------------

module "elasticache" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/elasticache?ref=v1.0.0"
  count  = local.enabled.elasticache ? 1 : 0

  name        = "${local.name_prefix}-redis"
  description = "Redis replication group for ${local.name_prefix}"

  engine_version         = try(local.config.elasticache.engine_version, "7.1")
  parameter_group_family = try(local.config.elasticache.parameter_group_family, "redis7")
  node_type              = try(local.config.elasticache.node_type, "cache.t4g.micro")
  port                   = local.cache_port

  subnet_group_name  = local.elasticache_subnet_group_name
  security_group_ids = [module.security_groups[0].elasticache_sg_id]

  num_cache_clusters         = local.hardened.elasticache_num_cache_clusters
  automatic_failover_enabled = local.hardened.elasticache_num_cache_clusters > 1
  multi_az_enabled           = local.hardened.elasticache_num_cache_clusters > 1

  kms_key_arn           = local.kms.secrets
  auth_token_secret_arn = try(local.config.elasticache.auth_token_secret_arn, null)

  snapshot_retention_limit = local.hardened.elasticache_snapshot_retention
  notification_topic_arn   = one(module.cloudwatch[*].sns_topic_arn)

  tags = local.common_tags
}

# ---- Lambda ---------------------------------------------------------------

module "lambda" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/lambda?ref=v1.0.0"
  count  = local.enabled.lambda ? 1 : 0

  name      = local.name_prefix
  functions = try(local.config.lambda.functions, {})

  subnet_ids         = local.private_subnet_ids
  security_group_ids = compact([module.security_groups[0].lambda_sg_id])
  kms_key_arn        = local.kms.secrets

  tags = local.common_tags
}
