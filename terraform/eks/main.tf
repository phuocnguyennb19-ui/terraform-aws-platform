data "aws_caller_identity" "current" {}

locals {
  kms = {
    ebs     = module.kms.key_arns["ebs"]
    rds     = module.kms.key_arns["rds"]
    logs    = module.kms.key_arns["logs"]
    secrets = module.kms.key_arns["secrets"]
    eks     = module.kms.key_arns["eks"]
    ecr     = module.kms.key_arns["ecr"]
  }

  # Iterate the counted modules rather than index them: [0] errors when the block is disabled.
  connection_env = merge(concat([{}],
    [for m in module.rds : { DATABASE_HOST = m.address, DATABASE_PORT = tostring(m.port), DATABASE_NAME = m.database_name }],
    [for m in module.elasticache : { REDIS_HOST = m.primary_endpoint_address, REDIS_PORT = tostring(m.port) }],
  )...)
}

module "kms" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/kms?ref=v2.0.0"

  name = local.name_prefix
  tags = local.common_tags

  keys = {
    ebs     = { description = "EBS volume encryption for ${local.name_prefix}", service_principals = ["ec2.amazonaws.com"] }
    rds     = { description = "RDS storage, snapshot and Performance Insights encryption for ${local.name_prefix}", service_principals = ["rds.amazonaws.com", "monitoring.rds.amazonaws.com"] }
    logs    = { description = "CloudWatch Logs encryption for ${local.name_prefix}", service_principals = ["logs.${local.region}.amazonaws.com"] }
    secrets = { description = "Secrets Manager and SNS encryption for ${local.name_prefix}", service_principals = ["secretsmanager.amazonaws.com", "sns.amazonaws.com", "cloudwatch.amazonaws.com"] }
    eks     = { description = "EKS envelope encryption for Kubernetes Secrets in ${local.name_prefix}", service_principals = ["eks.amazonaws.com"] }
    ecr     = { description = "ECR image layer encryption for ${local.name_prefix}", service_principals = ["ecr.amazonaws.com"] }
  }
}

module "vpc" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/vpc?ref=v2.0.0"

  name       = local.name_prefix
  cidr_block = local.env.vpc_cidr
  az_count   = local.env.az_count
  azs        = local.env.pin_azs ? [for s in ["a", "b", "c"] : "${local.region}${s}"] : null

  enable_nat_gateway     = true
  single_nat_gateway     = local.env.single_nat_gateway
  one_nat_gateway_per_az = !local.env.single_nat_gateway

  enable_flow_logs        = true
  flow_log_retention_days = local.env.flow_log_retention_days
  flow_log_kms_key_arn    = local.kms.logs

  create_database_subnet_group    = true
  create_elasticache_subnet_group = local.enabled.cache

  enable_s3_gateway_endpoint = true
  interface_endpoints        = local.env.interface_endpoints

  eks_cluster_names = [local.cluster_name]

  tags = local.common_tags
}

module "security_groups" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/security-groups?ref=v2.0.0"

  name           = local.name_prefix
  vpc_id         = module.vpc.vpc_id
  vpc_cidr_block = module.vpc.vpc_cidr_block

  create_eks_sg         = true
  create_rds_sg         = local.enabled.database
  create_elasticache_sg = local.enabled.cache

  application_port = local.service_port
  database_port    = 5432
  cache_port       = 6379

  eks_public_api_allowed_cidrs = local.env.eks_public_api ? local.env.eks_public_api_cidrs : []

  tags = local.common_tags
}

module "iam" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/iam?ref=v2.0.0"

  name = local.name_prefix

  create_rds_monitoring_role = local.enabled.database

  tags = local.common_tags
}

module "cloudwatch" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/cloudwatch?ref=v2.0.0"

  name = local.name_prefix

  create_sns_topic = true
  sns_kms_key_arn  = local.kms.secrets

  default_log_kms_key_arn = local.kms.logs

  # for-expressions, not ternaries: a ternary's branches must share one object type.
  metric_alarms = merge(
    { for k, v in local.rds_alarms : k => v if local.enabled.database },
    { for k, v in local.cache_alarms : k => v if local.enabled.cache },
  )

  create_dashboard = true

  tags = local.common_tags
}

module "ecr" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/ecr?ref=v2.0.0"
  count  = local.enabled.ecr ? 1 : 0

  # Repositories are eks/<image>: terraform/ecs owns the unprefixed names in the same account.
  name            = local.ecr_prefix
  use_name_prefix = true
  kms_key_arn     = local.kms.ecr

  repositories = {
    for repo in local.ecr_repositories : repo => {
      untagged_expiry_days = local.env.ecr_untagged_expiry_days
      keep_tagged_count    = local.env.ecr_keep_tagged_count
    }
  }

  tags = local.common_tags
}

module "eks" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/eks?ref=v2.0.0"

  cluster_name       = local.cluster_name
  kubernetes_version = local.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = local.env.eks_public_api
  cluster_endpoint_public_access_cidrs = local.env.eks_public_api_cidrs

  cluster_security_group_ids = compact([module.security_groups.eks_cluster_sg_id])
  node_security_group_ids    = compact([module.security_groups.eks_node_sg_id])

  node_groups = local.env.eks_node_groups

  access_entries = local.access_entries

  create_kms_key             = false
  kms_key_arn                = local.kms.eks
  cluster_log_kms_key_arn    = local.kms.logs
  cluster_log_retention_days = local.env.log_retention_days

  tags = local.common_tags
}

module "rds" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/rds?ref=v2.0.0"
  count  = local.enabled.database ? 1 : 0

  identifier = "${local.name_prefix}-postgres"

  engine               = "postgres"
  engine_version       = "16.4"
  family               = "postgres16"
  major_engine_version = "16"
  instance_class       = local.database_size.instance_class

  db_subnet_group_name = module.vpc.database_subnet_group_name
  security_group_ids   = compact([module.security_groups.rds_sg_id])

  allocated_storage     = local.database_size.allocated_storage
  max_allocated_storage = local.database_size.max_allocated_storage
  kms_key_arn           = local.kms.rds

  db_name                        = "appdb"
  username                       = "dbadmin"
  master_user_secret_kms_key_arn = local.kms.secrets

  multi_az                = local.env.rds_multi_az
  backup_retention_period = local.env.rds_backup_retention_days
  deletion_protection     = local.is_prod
  skip_final_snapshot     = !local.is_prod
  apply_immediately       = !local.is_prod

  monitoring_role_arn              = module.iam.rds_monitoring_role_arn
  performance_insights_kms_key_arn = local.kms.rds

  cloudwatch_log_group_retention_in_days = local.env.log_retention_days

  tags = local.common_tags
}

module "elasticache" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/elasticache?ref=v2.0.0"
  count  = local.enabled.cache ? 1 : 0

  name        = "${local.name_prefix}-redis"
  description = "Redis replication group for ${local.name_prefix}"

  engine_version         = "7.1"
  parameter_group_family = "redis7"
  node_type              = local.cache_size
  port                   = 6379

  subnet_group_name  = module.vpc.elasticache_subnet_group_name
  security_group_ids = compact([module.security_groups.elasticache_sg_id])

  num_cache_clusters         = local.env.cache_nodes
  automatic_failover_enabled = local.env.cache_nodes > 1
  multi_az_enabled           = local.env.cache_nodes > 1

  kms_key_arn = local.kms.secrets

  snapshot_retention_limit = local.is_prod ? 7 : 1
  notification_topic_arn   = module.cloudwatch.sns_topic_arn

  tags = local.common_tags
}

# One release of the pinned chart per service. atomic rolls a failed upgrade back to the
# previous revision instead of leaving the release half-applied.
resource "helm_release" "service" {
  for_each = local.release_specs

  name             = each.key
  namespace        = local.namespace
  create_namespace = true

  repository = local.chart.repository
  chart      = local.chart.name
  version    = local.chart.version

  values = [yamlencode(merge(each.value.values, {
    env = merge(local.connection_env, local.services[each.key].env)
  }))]

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600
  max_history     = 10

  # Nodes, not just the control plane: a release waits for its pods to become ready.
  depends_on = [module.eks, terraform_data.config]
}
