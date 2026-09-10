# ===========================================================================
# PRODUCTION
#
# Several controls in this file cannot be weakened from here. main.tf applies a
# hardening floor when environment == "prod" — multi-AZ, deletion protection,
# a final snapshot on delete, 30 days of backups, flow logs, a private EKS API
# endpoint, one NAT gateway per AZ, and a 90-day log retention minimum. Setting
# a weaker value below has no effect; the floor wins.
#
# That is deliberate. A control that can be switched off by editing a values
# file is a control that eventually gets switched off in a hurry, by someone
# chasing an unrelated failure at 03:00.
#
# No secret belongs in this file.
# ===========================================================================

environment = "prod"
region      = "ap-southeast-1"
project     = "platform"
owner       = "platform-engineering"
cost_center = "production"

# Apply into the production account by assuming a role, rather than with a
# long-lived key. Every API call is then attributable to this environment.
# assume_role_arn = "arn:aws:iam::111122223333:role/terraform-platform-prod"

# Cap what any role this stack creates can ever be granted, including by a
# later change nobody reviewed closely.
# permissions_boundary_arn = "arn:aws:iam::111122223333:policy/platform-boundary"

# ---------------------------------------------------------------------------
# Foundation
# ---------------------------------------------------------------------------

vpc_cidr = "10.30.0.0/16"
az_count = 3

# Pin the AZs. Without this, a change in the order the region reports its zones
# renumbers every subnet, which Terraform plans as a destroy and recreate of the
# entire network.
azs = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

# Forced to false by the prod floor regardless of this value.
single_nat_gateway = false

enable_flow_logs        = true
flow_log_retention_days = 365

# Interface endpoints so nodes reach ECR, CloudWatch and SSM without traversing
# the NAT gateway. Each is billed hourly per AZ and usually pays for itself on
# image pull volume alone.
interface_endpoints = ["ecr.api", "ecr.dkr", "logs", "ssm", "ssmmessages", "ec2messages", "sts", "kms"]

# ---------------------------------------------------------------------------
# Workloads
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
# ---------------------------------------------------------------------------

domain_name     = "example.com" # REPLACE
create_dns_zone = false
app_hostname    = "api"

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------

alb_internal                   = false
alb_ingress_cidrs              = ["0.0.0.0/0"]
application_port               = 8080
health_check_path              = "/healthz"
alb_access_logs_retention_days = 365

# ---------------------------------------------------------------------------
# EKS
#
# The API endpoint is private. Forced by the prod floor whatever is set here —
# reach the cluster from a CI runner inside the VPC, a VPN, or Session Manager
# onto a host in a private subnet.
# ---------------------------------------------------------------------------

kubernetes_version = "1.31"

eks_public_api_access = false
eks_public_api_cidrs  = []

eks_node_groups = {
  # On-demand capacity floor. A cluster with only spot capacity has no floor at
  # all when the spot pool is exhausted, which happens at the worst moment.
  general = {
    instance_types = ["m6i.xlarge"]
    capacity_type  = "ON_DEMAND"
    min_size       = 3
    max_size       = 12
    desired_size   = 3
    disk_size      = 100
    labels         = { workload = "general" }
  }

  # Burstable capacity on top, tainted so only workloads that tolerate an
  # interruption land here.
  spot = {
    instance_types = ["m6i.xlarge", "m6a.xlarge", "m5.xlarge"]
    capacity_type  = "SPOT"
    min_size       = 0
    max_size       = 20
    desired_size   = 2
    disk_size      = 100
    labels         = { workload = "burstable" }
    taints = {
      spot = { key = "capacity", value = "spot", effect = "NO_SCHEDULE" }
    }
  }
}

# ---------------------------------------------------------------------------
# RDS
#
# multi_az, deletion_protection, backup retention >= 30 days and a final
# snapshot on delete are all forced by the prod floor.
# ---------------------------------------------------------------------------

rds_engine                = "postgres"
rds_engine_version        = "16.4"
rds_family                = "postgres16"
rds_major_engine_version  = "16"
rds_instance_class        = "db.r6g.xlarge"
rds_allocated_storage     = 200
rds_max_allocated_storage = 1000

rds_multi_az                = true
rds_backup_retention_period = 30

rds_database_name = "appdb"
rds_username      = "dbadmin"

# ---------------------------------------------------------------------------
# ElastiCache
# ---------------------------------------------------------------------------

elasticache_node_type              = "cache.r7g.large"
elasticache_engine_version         = "7.1"
elasticache_parameter_group_family = "redis7"
elasticache_num_cache_clusters     = 3

# elasticache_auth_token_secret_arn = "arn:aws:secretsmanager:ap-southeast-1:111122223333:secret:prod/redis/auth-AbCdEf"

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

ecr_use_name_prefix = false

ecr_repositories = {
  api = {
    image_tag_mutability = "IMMUTABLE"
    scan_on_push         = true
    untagged_expiry_days = 14
    keep_tagged_count    = 100
  }
}

# ---------------------------------------------------------------------------
# Observability
#
# An alarm with no subscription is a dashboard widget. Fill this in before the
# first production apply, not after the first incident.
# ---------------------------------------------------------------------------

log_retention_days     = 365
create_alarm_dashboard = true

alarm_subscriptions = {
  # oncall = { protocol = "https", endpoint = "https://events.pagerduty.com/integration/REPLACE/enqueue" }
}
