# ===========================================================================
# STAGING
#
# Structurally identical to prod — same topology, same controls, same
# multi-AZ posture — at smaller instance sizes. That is the whole point of a
# staging environment: a procedure rehearsed here is a procedure that will
# behave the same way in prod. Where staging diverges structurally from prod,
# it stops being a rehearsal and becomes a second dev.
# ===========================================================================

environment = "staging"
region      = "ap-southeast-1"
project     = "platform"
owner       = "platform-engineering"
cost_center = "engineering-staging"

# ---------------------------------------------------------------------------
# Foundation
# ---------------------------------------------------------------------------

vpc_cidr = "10.20.0.0/16"
az_count = 3

# One NAT per AZ, as in prod. A staging environment that survives an AZ failure
# differently from prod has not rehearsed anything.
single_nat_gateway = false

enable_flow_logs        = true
flow_log_retention_days = 30

# ---------------------------------------------------------------------------
# Workloads — the same set as prod
# ---------------------------------------------------------------------------

enable_alb         = true
enable_eks         = true
enable_ec2         = false
enable_rds         = true
enable_elasticache = true
enable_lambda      = false
enable_ecr         = true
enable_route53     = true
enable_acm         = true

# ---------------------------------------------------------------------------
# DNS
#
# create_dns_zone = false: the zone is registered once and delegated. Creating a
# zone that already exists elsewhere produces a second zone with different
# nameservers and no error — the records simply never resolve.
# ---------------------------------------------------------------------------

domain_name     = "staging.example.com" # REPLACE with your delegated zone
create_dns_zone = false
app_hostname    = "api"

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------

alb_internal                   = false
alb_ingress_cidrs              = ["0.0.0.0/0"]
application_port               = 8080
health_check_path              = "/healthz"
alb_access_logs_retention_days = 30

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------

kubernetes_version = "1.31"

# Public API access, narrowed to the CI and office ranges. Prod forces this off.
eks_public_api_access = true
eks_public_api_cidrs  = ["203.0.113.0/24"] # REPLACE

eks_node_groups = {
  general = {
    instance_types = ["t3.large"]
    capacity_type  = "ON_DEMAND"
    min_size       = 2
    max_size       = 6
    desired_size   = 2
    disk_size      = 50
    labels         = { workload = "general" }
  }

  spot = {
    instance_types = ["t3.large", "t3a.large", "m5.large"]
    capacity_type  = "SPOT"
    min_size       = 0
    max_size       = 6
    desired_size   = 1
    disk_size      = 50
    labels         = { workload = "burstable" }
    taints = {
      spot = { key = "capacity", value = "spot", effect = "NO_SCHEDULE" }
    }
  }
}

# ---------------------------------------------------------------------------
# RDS
# ---------------------------------------------------------------------------

rds_engine                = "postgres"
rds_engine_version        = "16.4"
rds_family                = "postgres16"
rds_major_engine_version  = "16"
rds_instance_class        = "db.t4g.large"
rds_allocated_storage     = 50
rds_max_allocated_storage = 200

# Multi-AZ on, as in prod: a failover rehearsed here is a failover that will
# behave the same way in prod.
rds_multi_az                = true
rds_backup_retention_period = 7

rds_database_name = "appdb"
rds_username      = "dbadmin"

# ---------------------------------------------------------------------------
# ElastiCache
# ---------------------------------------------------------------------------

elasticache_node_type              = "cache.t4g.small"
elasticache_engine_version         = "7.1"
elasticache_parameter_group_family = "redis7"
elasticache_num_cache_clusters     = 2

# Create the secret outside Terraform so the token never enters state.
# elasticache_auth_token_secret_arn = "arn:aws:secretsmanager:ap-southeast-1:111122223333:secret:staging/redis/auth-AbCdEf"

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

ecr_use_name_prefix = false

ecr_repositories = {
  api = {
    image_tag_mutability = "IMMUTABLE"
    scan_on_push         = true
    untagged_expiry_days = 7
    keep_tagged_count    = 30
  }
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

log_retention_days     = 30
create_alarm_dashboard = true

alarm_subscriptions = {
  # oncall = { protocol = "https", endpoint = "https://events.pagerduty.com/integration/REPLACE/enqueue" }
}
