output "environment" {
  description = "Environment this stack built. Check this before trusting anything else in the output."
  value       = local.environment
}

output "account_id" {
  description = "AWS account the provider is authenticated against."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "AWS region."
  value       = local.region
}

output "vpc_id" {
  description = "VPC every stack in this environment runs in."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets — ECS tasks and EKS nodes."
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnets — the ALB only."
  value       = module.vpc.public_subnet_ids
}

output "kms" {
  description = "Customer-managed keys by purpose. A runtime stack encrypts its logs and volumes with these."
  value       = local.kms
}

output "security_group_ids" {
  description = "Security groups by role. Empty where the config asks for nothing that needs one."
  value = {
    alb         = module.security_groups.alb_sg_id
    ecs         = module.security_groups.ecs_sg_id
    eks_cluster = module.security_groups.eks_cluster_sg_id
    eks_node    = module.security_groups.eks_node_sg_id
    rds         = module.security_groups.rds_sg_id
    elasticache = module.security_groups.elasticache_sg_id
  }
}

output "sns_topic_arn" {
  description = "Topic every alarm in every stack publishes to."
  value       = module.cloudwatch.sns_topic_arn
}

# Built here because the database and the cache are built here; both runtimes hand it to their
# services unchanged, so a service reaches the same database whichever runtime it runs on.
output "connection_env" {
  description = "Database and cache connection variables every service receives."
  value = merge(concat([{}],
    [for m in module.rds : { DATABASE_HOST = m.address, DATABASE_PORT = tostring(m.port), DATABASE_NAME = m.database_name }],
    [for m in module.elasticache : { REDIS_HOST = m.primary_endpoint_address, REDIS_PORT = tostring(m.port) }],
  )...)
}

output "ecr_repository_urls" {
  description = "Repository name to registry URL — what a CI build tags and pushes an image to. Shared by both runtimes."
  value       = try(module.ecr[0].repository_urls, {})
}

output "database_endpoint" {
  description = "RDS endpoint, or null without a database."
  value       = one(module.rds[*].endpoint)
}

output "database_master_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials — reference it, never copy the value."
  value       = one(module.rds[*].master_user_secret_arn)
}

output "redis_endpoint" {
  description = "Redis primary endpoint, or null without a cache."
  value       = one(module.elasticache[*].primary_endpoint_address)
}
