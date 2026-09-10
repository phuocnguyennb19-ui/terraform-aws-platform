# ===========================================================================
# ENVIRONMENT COMPOSITION
#
# Identical in dev, staging and prod. Only terraform.tfvars and backend.hcl
# differ; `make env-drift` fails if that stops being true.
#
# Dependency order is expressed entirely through module outputs feeding module
# inputs. There is not one depends_on in this file: Terraform derives the graph
# from the references themselves, and an explicit depends_on here would only
# serialise things that could otherwise run in parallel.
#
#   kms ──┐
#         ├──▶ vpc ──┬──▶ security_groups ──┬──▶ alb ──▶ route53 (alias record)
#   iam ──┘          │                      ├──▶ eks
#                    │                      ├──▶ ec2
#                    │                      ├──▶ rds
#                    │                      ├──▶ elasticache
#                    │                      └──▶ lambda
#                    │
#   route53 (zone) ──▶ acm ──▶ alb ──▶ aws_route53_record.app (alias)
#
# The alias record is a bare resource here rather than an input to the route53
# module on purpose. Routing it through the module would make route53 depend on
# alb, while alb already depends on acm which depends on route53's zone id — a
# cycle Terraform rejects outright. Splitting "own the zone" from "write one
# record into it" is what breaks it.
# ===========================================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
  is_prod     = var.environment == "prod"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      Owner       = var.owner
      CostCenter  = var.cost_center
      ManagedBy   = "terraform"
      Repository  = "terraform-aws-platform"
    },
    var.additional_tags,
  )

  # -------------------------------------------------------------------------
  # Production hardening floor
  #
  # Production does not get to opt out of these from a tfvars file. A control
  # that can be switched off by editing a values file is a control that will
  # eventually be switched off by accident, in a hurry, by someone chasing an
  # unrelated failure. Raising a value above the floor is still allowed; going
  # below it is not expressible.
  #
  # Each line names what it protects:
  #   multi_az / one NAT per AZ  — an AZ failure is a failover, not an outage
  #   deletion_protection        — a mistargeted destroy stops at the database
  #   skip_final_snapshot=false  — deletion leaves a restorable copy behind
  #   backup retention >= 30d    — a corruption found in week three is still recoverable
  #   flow logs                  — the only record of who talked to what
  #   private EKS API            — the control plane is not on the internet
  # -------------------------------------------------------------------------
  hardened = {
    single_nat_gateway      = local.is_prod ? false : var.single_nat_gateway
    enable_flow_logs        = local.is_prod ? true : var.enable_flow_logs
    flow_log_retention_days = local.is_prod ? max(var.flow_log_retention_days, 90) : var.flow_log_retention_days
    log_retention_days      = local.is_prod ? max(var.log_retention_days, 90) : var.log_retention_days

    rds_multi_az                = local.is_prod ? true : var.rds_multi_az
    rds_backup_retention_period = local.is_prod ? max(var.rds_backup_retention_period, 30) : var.rds_backup_retention_period
    rds_deletion_protection     = local.is_prod
    rds_skip_final_snapshot     = !local.is_prod
    rds_apply_immediately       = !local.is_prod

    alb_deletion_protection = local.is_prod

    eks_public_api_access = local.is_prod ? false : var.eks_public_api_access

    elasticache_num_cache_clusters = local.is_prod ? max(var.elasticache_num_cache_clusters, 2) : var.elasticache_num_cache_clusters
    elasticache_snapshot_retention = local.is_prod ? 7 : 1

    ec2_termination_protection = local.is_prod
  }

  # An EKS cluster in this VPC needs its discovery tags on the subnets. The name
  # is derived rather than taken from the eks module, which would be a cycle:
  # the VPC has to exist before the cluster that tags it.
  eks_cluster_name  = "${local.name_prefix}-eks"
  eks_cluster_names = var.enable_eks ? [local.eks_cluster_name] : []

  # The fully qualified name the ALB is published under.
  app_fqdn = var.enable_route53 && var.domain_name != null ? (
    var.app_hostname != null ? "${var.app_hostname}.${var.domain_name}" : var.domain_name
  ) : null

  rds_port   = var.rds_engine == "postgres" ? 5432 : 3306
  cache_port = 6379

  # -------------------------------------------------------------------------
  # Alarm definitions
  #
  # Declared unconditionally and filtered where they are consumed. Every one of
  # them publishes to the module's SNS topic on both ALARM and OK.
  # -------------------------------------------------------------------------
  rds_identifier = "${local.name_prefix}-${var.rds_engine}"

  rds_alarms = {
    rds-cpu = {
      alarm_description   = "RDS CPU above 80% for 10 minutes on ${local.name_prefix}"
      namespace           = "AWS/RDS"
      metric_name         = "CPUUtilization"
      dimensions          = { DBInstanceIdentifier = local.rds_identifier }
      threshold           = 80
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 2
      severity            = "warning"
    }

    # 10 GiB in bytes. Storage autoscaling should act first; this fires when it
    # has not, which is the point at which the database is minutes from read-only.
    rds-free-storage = {
      alarm_description   = "RDS free storage below 10 GiB on ${local.name_prefix}"
      namespace           = "AWS/RDS"
      metric_name         = "FreeStorageSpace"
      dimensions          = { DBInstanceIdentifier = local.rds_identifier }
      threshold           = 10737418240
      comparison_operator = "LessThanThreshold"
      evaluation_periods  = 1
      severity            = "critical"
    }

    rds-connections = {
      alarm_description   = "RDS connection count unusually high on ${local.name_prefix}"
      namespace           = "AWS/RDS"
      metric_name         = "DatabaseConnections"
      dimensions          = { DBInstanceIdentifier = local.rds_identifier }
      threshold           = 200
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
      severity            = "warning"
    }
  }

  alb_alarms = {
    # ELB_5XX, not TARGET_5XX: this counts errors the load balancer generated
    # itself — no healthy target, or a target that never answered — rather than
    # errors the application returned deliberately.
    alb-5xx = {
      alarm_description   = "ALB returning 5xx from its own layer on ${local.name_prefix}"
      namespace           = "AWS/ApplicationELB"
      metric_name         = "HTTPCode_ELB_5XX_Count"
      statistic           = "Sum"
      dimensions          = { LoadBalancer = one(module.alb[*].arn_suffix) }
      threshold           = 10
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 2
      treat_missing_data  = "notBreaching"
      severity            = "critical"
    }

    alb-unhealthy-hosts = {
      alarm_description   = "ALB has unhealthy targets on ${local.name_prefix}"
      namespace           = "AWS/ApplicationELB"
      metric_name         = "UnHealthyHostCount"
      statistic           = "Maximum"
      dimensions          = { LoadBalancer = one(module.alb[*].arn_suffix) }
      threshold           = 0
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 2
      treat_missing_data  = "missing"
      severity            = "critical"
    }

    alb-target-latency = {
      alarm_description   = "ALB p99 target response time above 2s on ${local.name_prefix}"
      namespace           = "AWS/ApplicationELB"
      metric_name         = "TargetResponseTime"
      extended_statistic  = "p99"
      dimensions          = { LoadBalancer = one(module.alb[*].arn_suffix) }
      threshold           = 2
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
      treat_missing_data  = "notBreaching"
      severity            = "warning"
    }
  }

  cache_alarms = {
    cache-evictions = {
      alarm_description   = "ElastiCache is evicting keys on ${local.name_prefix} — the working set no longer fits"
      namespace           = "AWS/ElastiCache"
      metric_name         = "Evictions"
      statistic           = "Sum"
      dimensions          = { ReplicationGroupId = "${local.name_prefix}-redis" }
      threshold           = 0
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
      treat_missing_data  = "notBreaching"
      severity            = "warning"
    }

    cache-cpu = {
      alarm_description   = "ElastiCache engine CPU above 75% on ${local.name_prefix}"
      namespace           = "AWS/ElastiCache"
      metric_name         = "EngineCPUUtilization"
      dimensions          = { ReplicationGroupId = "${local.name_prefix}-redis" }
      threshold           = 75
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
      severity            = "warning"
    }
  }
}

# ===========================================================================
# FOUNDATION
# ===========================================================================

# ---- KMS ------------------------------------------------------------------
# One key per purpose. Created before anything that references it, which is
# every encrypted resource in the environment.

module "kms" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/kms?ref=v1.0.0"

  name = local.name_prefix
  tags = local.common_tags

  keys = {
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
      service_principals = ["logs.${var.region}.amazonaws.com"]
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
}

# ---- VPC ------------------------------------------------------------------
# The single network boundary. Everything below consumes its outputs; nothing
# below creates a VPC, a subnet, a NAT gateway or a route table.

module "vpc" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/vpc?ref=v1.0.0"

  name       = local.name_prefix
  cidr_block = var.vpc_cidr
  az_count   = var.az_count
  azs        = var.azs

  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = local.hardened.single_nat_gateway
  one_nat_gateway_per_az = !local.hardened.single_nat_gateway

  enable_flow_logs        = local.hardened.enable_flow_logs
  flow_log_retention_days = local.hardened.flow_log_retention_days
  flow_log_kms_key_arn    = module.kms.key_arns["logs"]

  create_database_subnet_group    = true
  create_elasticache_subnet_group = var.enable_elasticache

  enable_s3_gateway_endpoint = true

  # No security group is passed: the vpc module creates its own for the
  # endpoints. Taking one from the security-groups module would be a cycle,
  # since that module needs vpc_id from here.
  interface_endpoints = var.interface_endpoints

  eks_cluster_names = local.eks_cluster_names

  tags = local.common_tags
}

# ---- Security groups ------------------------------------------------------
# Consumes vpc_id. Every workload below takes its security group from here
# rather than creating one, so the tier-to-tier rules live in a single place.

module "security_groups" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/security-groups?ref=v1.0.0"

  name           = local.name_prefix
  vpc_id         = module.vpc.vpc_id
  vpc_cidr_block = module.vpc.vpc_cidr_block

  create_alb_sg         = var.enable_alb
  create_eks_sg         = var.enable_eks
  create_ec2_sg         = var.enable_ec2
  create_rds_sg         = var.enable_rds
  create_elasticache_sg = var.enable_elasticache
  create_lambda_sg      = var.enable_lambda
  create_bastion_sg     = var.enable_bastion_sg

  application_port = var.application_port
  database_port    = local.rds_port
  cache_port       = local.cache_port

  alb_ingress_cidrs            = var.alb_ingress_cidrs
  bastion_allowed_cidrs        = var.bastion_allowed_cidrs
  eks_public_api_allowed_cidrs = local.hardened.eks_public_api_access ? var.eks_public_api_cidrs : []

  tags = local.common_tags
}

# ---- IAM baseline ---------------------------------------------------------

module "iam" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/iam?ref=v1.0.0"

  name                     = local.name_prefix
  permissions_boundary_arn = var.permissions_boundary_arn

  create_ec2_instance_role   = var.enable_ec2
  create_rds_monitoring_role = var.enable_rds

  # Iterating the module rather than indexing it: module.ecr[0] is an error when
  # enable_ecr is false, and a conditional does not reliably guard against it.
  ec2_ecr_pull_repository_arns = flatten([for m in module.ecr : values(m.repository_arns)])
  ec2_kms_key_arns             = [module.kms.key_arns["ebs"]]

  tags = local.common_tags
}

# ===========================================================================
# SHARED SERVICES
# ===========================================================================

# ---- CloudWatch: log groups, alarms, and the topic they publish to --------

module "cloudwatch" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/cloudwatch?ref=v1.0.0"

  name = local.name_prefix

  create_sns_topic  = true
  sns_kms_key_arn   = module.kms.key_arns["secrets"]
  sns_subscriptions = var.alarm_subscriptions

  default_log_kms_key_arn = module.kms.key_arns["logs"]

  log_groups = {
    application = {
      name              = "/${var.project}/${var.environment}/application"
      retention_in_days = local.hardened.log_retention_days
    }
  }

  # Filtered with a for-expression, not a conditional. Terraform requires both
  # branches of a ternary to have the same object type, and "the RDS alarms" and
  # "{}" never will — a for-expression with an `if` sidesteps that entirely.
  metric_alarms = merge(
    { for k, v in local.rds_alarms : k => v if var.enable_rds },
    { for k, v in local.alb_alarms : k => v if var.enable_alb },
    { for k, v in local.cache_alarms : k => v if var.enable_elasticache },
  )

  create_dashboard = var.create_alarm_dashboard

  tags = local.common_tags
}

# ---- ECR ------------------------------------------------------------------

module "ecr" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/ecr?ref=v1.0.0"
  count  = var.enable_ecr ? 1 : 0

  name            = local.name_prefix
  use_name_prefix = var.ecr_use_name_prefix
  repositories    = var.ecr_repositories
  kms_key_arn     = module.kms.key_arns["ecr"]

  tags = local.common_tags
}

# ---- Route53 --------------------------------------------------------------
# Composed before ACM: the certificate's DNS validation records are written
# into this zone, so the zone ID has to exist first.

module "route53" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/route53?ref=v1.0.0"
  count  = var.enable_route53 ? 1 : 0

  zone_name   = var.domain_name
  create_zone = var.create_dns_zone

  # Records are written below, not here — see the note in the header about the
  # alb/acm/route53 cycle.
  records = {}

  tags = local.common_tags
}

# ---- The ALB alias record -------------------------------------------------
# An alias rather than a CNAME: it resolves at no charge, follows the load
# balancer's addresses automatically, and is the only record type that can sit
# on a zone apex.

resource "aws_route53_record" "app" {
  count = var.enable_route53 && var.enable_alb ? 1 : 0

  zone_id = module.route53[0].zone_id
  name    = local.app_fqdn
  type    = "A"

  alias {
    name                   = module.alb[0].dns_name
    zone_id                = module.alb[0].zone_id
    evaluate_target_health = true
  }
}

# ---- ACM ------------------------------------------------------------------

module "acm" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/acm?ref=v1.0.0"
  count  = var.enable_acm && var.enable_route53 ? 1 : 0

  domain_name               = local.app_fqdn
  subject_alternative_names = var.certificate_sans
  zone_id                   = one(module.route53[*].zone_id)

  tags = local.common_tags
}

# ---- ALB ------------------------------------------------------------------
# Consumes the foundation's PUBLIC subnets (or private ones when internal),
# the ALB security group, and the ACM certificate.

module "alb" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/alb?ref=v1.0.0"
  count  = var.enable_alb ? 1 : 0

  name   = substr("${local.name_prefix}-alb", 0, 32)
  vpc_id = module.vpc.vpc_id

  subnet_ids         = var.alb_internal ? module.vpc.private_subnet_ids : module.vpc.public_subnet_ids
  security_group_ids = [module.security_groups.alb_sg_id]
  internal           = var.alb_internal

  certificate_arn = one(module.acm[*].certificate_arn)

  target_groups = {
    app = {
      port        = var.application_port
      protocol    = "HTTP"
      target_type = var.enable_eks ? "ip" : "instance"

      health_check = {
        path = var.health_check_path
      }
    }
  }

  default_target_group_key = "app"

  enable_deletion_protection = local.hardened.alb_deletion_protection
  enable_access_logs         = true
  access_logs_retention_days = var.alb_access_logs_retention_days

  tags = local.common_tags
}

# ===========================================================================
# WORKLOADS
#
# Every one of these takes vpc_id / subnet IDs / security group IDs as inputs.
# None of them creates network infrastructure.
# ===========================================================================

# ---- EKS ------------------------------------------------------------------

module "eks" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/eks?ref=v1.0.0"
  count  = var.enable_eks ? 1 : 0

  cluster_name       = local.eks_cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = local.hardened.eks_public_api_access
  cluster_endpoint_public_access_cidrs = var.eks_public_api_cidrs

  cluster_security_group_ids = [module.security_groups.eks_cluster_sg_id]
  node_security_group_ids    = [module.security_groups.eks_node_sg_id]

  node_groups = var.eks_node_groups

  kms_key_arn                = module.kms.key_arns["eks"]
  cluster_log_kms_key_arn    = module.kms.key_arns["logs"]
  cluster_log_retention_days = local.hardened.log_retention_days

  irsa_roles     = var.eks_irsa_roles
  access_entries = var.eks_access_entries

  tags = local.common_tags
}

# ---- EC2 ------------------------------------------------------------------

module "ec2" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/ec2?ref=v1.0.0"
  count  = var.enable_ec2 ? 1 : 0

  name = local.name_prefix

  instances = {
    for k, i in var.ec2_instances : k => {
      # Resolved from the foundation. An environment names an index, not a
      # subnet ID that does not exist until the VPC is applied.
      subnet_id = module.vpc.private_subnet_ids[
        i.subnet_index % length(module.vpc.private_subnet_ids)
      ]
      instance_type    = i.instance_type
      ami_id           = i.ami_id
      root_volume_size = i.root_volume_size
      user_data        = i.user_data
      tags             = i.tags
    }
  }

  security_group_ids   = [module.security_groups.ec2_sg_id]
  iam_instance_profile = module.iam.ec2_instance_profile_name
  kms_key_arn          = module.kms.key_arns["ebs"]

  enable_termination_protection_default = local.hardened.ec2_termination_protection

  tags = local.common_tags
}

# ---- RDS ------------------------------------------------------------------
# Database subnet group and RDS security group both come from the foundation.

module "rds" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/rds?ref=v1.0.0"
  count  = var.enable_rds ? 1 : 0

  identifier = local.rds_identifier

  engine               = var.rds_engine
  engine_version       = var.rds_engine_version
  family               = var.rds_family
  major_engine_version = var.rds_major_engine_version
  instance_class       = var.rds_instance_class

  db_subnet_group_name = module.vpc.database_subnet_group_name
  security_group_ids   = [module.security_groups.rds_sg_id]

  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage
  kms_key_arn           = module.kms.key_arns["rds"]

  db_name  = var.rds_database_name
  username = var.rds_username
  # No password argument exists. AWS generates it into Secrets Manager.
  master_user_secret_kms_key_arn = module.kms.key_arns["secrets"]

  multi_az                = local.hardened.rds_multi_az
  backup_retention_period = local.hardened.rds_backup_retention_period
  deletion_protection     = local.hardened.rds_deletion_protection
  skip_final_snapshot     = local.hardened.rds_skip_final_snapshot
  apply_immediately       = local.hardened.rds_apply_immediately

  monitoring_role_arn              = module.iam.rds_monitoring_role_arn
  performance_insights_kms_key_arn = module.kms.key_arns["rds"]

  cloudwatch_log_group_retention_in_days = local.hardened.log_retention_days

  tags = local.common_tags
}

# ---- ElastiCache ----------------------------------------------------------

module "elasticache" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/elasticache?ref=v1.0.0"
  count  = var.enable_elasticache ? 1 : 0

  name        = "${local.name_prefix}-redis"
  description = "Redis replication group for ${local.name_prefix}"

  engine_version         = var.elasticache_engine_version
  parameter_group_family = var.elasticache_parameter_group_family
  node_type              = var.elasticache_node_type
  port                   = local.cache_port

  subnet_group_name  = module.vpc.elasticache_subnet_group_name
  security_group_ids = [module.security_groups.elasticache_sg_id]

  num_cache_clusters         = local.hardened.elasticache_num_cache_clusters
  automatic_failover_enabled = local.hardened.elasticache_num_cache_clusters > 1
  multi_az_enabled           = local.hardened.elasticache_num_cache_clusters > 1

  kms_key_arn           = module.kms.key_arns["secrets"]
  auth_token_secret_arn = var.elasticache_auth_token_secret_arn

  snapshot_retention_limit = local.hardened.elasticache_snapshot_retention
  notification_topic_arn   = module.cloudwatch.sns_topic_arn

  tags = local.common_tags
}

# ---- Lambda ---------------------------------------------------------------

module "lambda" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/lambda?ref=v1.0.0"
  count  = var.enable_lambda ? 1 : 0

  name      = local.name_prefix
  functions = var.lambda_functions

  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = compact([module.security_groups.lambda_sg_id])
  kms_key_arn        = module.kms.key_arns["secrets"]

  tags = local.common_tags
}
