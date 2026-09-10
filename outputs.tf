# ===========================================================================
# STACK OUTPUTS
#
# These are the values an application stack needs in order to find a base stack,
# and the values a deployment log needs in order to say what was released.
#
# Named by what they are, not by which module produced them: a consumer should
# not have to care whether `vpc_id` came from a vpc module in this state or a
# tag lookup against someone else's.
# ===========================================================================

output "environment" {
  description = "Environment this stack built, straight from the config. Check this before trusting anything else in the output."
  value       = local.environment
}

output "region" {
  description = "AWS region."
  value       = local.region
}

output "account_id" {
  description = "AWS account the provider is authenticated against — after assume_role, if one was configured. This is the value to compare against the account you meant to deploy into."
  value       = data.aws_caller_identity.current.account_id
}

output "name_prefix" {
  description = "<project>-<environment>. The prefix every resource name in this stack is built from."
  value       = local.name_prefix
}

output "enabled_modules" {
  description = "Which modules this config switched on. The fastest way to see whether a config did what its author thought."
  value       = { for k, v in local.enabled : k => v if v }
}

# ---- Network --------------------------------------------------------------

output "vpc_id" {
  description = "VPC this stack built or found."
  value       = local.vpc_id
}

output "private_subnet_ids" {
  description = "Private application subnets. Where ECS tasks, EKS nodes and Lambda ENIs are placed."
  value       = local.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnets. Empty for an application stack that did not build the VPC."
  value       = local.public_subnet_ids
}

# ---- Edge -----------------------------------------------------------------

output "alb_dns_name" {
  description = "Load balancer DNS name, or null when this stack has no ALB."
  value       = one(module.alb[*].dns_name)
}

output "alb_target_group_arns" {
  description = "Target groups available to services in this stack — built here or looked up from the base stack. The keys are what an ecs_services entry names in target_group_key."
  value       = local.target_group_arns
}

output "app_url" {
  description = "The name the application is published under, or null when no DNS is managed here."
  value       = local.app_fqdn != null ? "https://${local.app_fqdn}" : null
}

# ---- ECS ------------------------------------------------------------------

output "ecs_cluster_arn" {
  description = "ECS cluster this stack built or found. This is the value an application config puts under existing.ecs_cluster."
  value       = local.cluster_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name — the --cluster argument, and the ClusterName metric dimension."
  value       = local.ecs_cluster_name
}

output "ecs_task_definition_arns" {
  description = "Map of service key to the task definition revision this apply produced. Record this: it is the only unambiguous answer to \"what is running\", and the value a rollback re-deploys."
  value       = { for k, s in module.ecs_service : k => s.task_definition_arn }
}

output "ecs_task_role_arns" {
  description = "Map of service key to task role ARN — the principal to name in an S3 bucket policy or a KMS key policy so the application can reach it."
  value       = { for k, s in module.ecs_service : k => s.tasks_iam_role_arn }
}

output "ecs_task_exec_role_arns" {
  description = "Map of service key to execution role ARN. A secret's resource policy must name THIS role, not the task role — the execution role is what fetches the secret before the container starts."
  value       = { for k, s in module.ecs_service : k => s.task_exec_iam_role_arn }
}

# ---- Registry and data ----------------------------------------------------

output "ecr_repository_urls" {
  description = "Map of repository key to registry URL. This is what a CI build tags an image with."
  value       = try(module.ecr[0].repository_urls, {})
}

output "rds_endpoint" {
  description = "RDS endpoint, or null when this stack has no database. The password is in Secrets Manager and never passes through Terraform."
  value       = try(module.rds[0].endpoint, null)
}

output "kms_key_arns" {
  description = "Map of purpose to KMS key ARN, whether created here or resolved from an alias."
  value       = local.kms_key_arns
}

output "sns_alarm_topic_arn" {
  description = "Topic every alarm in this stack publishes to."
  value       = one(module.cloudwatch[*].sns_topic_arn)
}
