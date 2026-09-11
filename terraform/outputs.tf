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

output "service_urls" {
  description = "Where each public service answers: https://<service>.<dns.domain>, or the ALB address when no domain is set."
  value = {
    for name, s in local.public_services : name => (
      local.enabled.dns ? "https://${name}.${local.dns_domain}" : "http://${module.alb[0].dns_name}"
    )
  }
}

output "service_internal_urls" {
  description = "How one service calls another privately, through ECS Service Connect: http://<service>:8080. The call never leaves the VPC."
  value       = { for name, s in local.service_specs : name => s.internal_url }
}

output "ecr_repository_urls" {
  description = "Repository name to registry URL — what a CI build tags and pushes an image to."
  value       = try(module.ecr[0].repository_urls, {})
}

output "ecs_cluster_name" {
  description = "ECS cluster name — the --cluster argument, and the ClusterName metric dimension."
  value       = one(module.ecs_cluster[*].name)
}

output "ecs_task_definition_arns" {
  description = "Service to the task definition revision this apply produced — the value a rollback re-deploys."
  value       = { for k, s in module.ecs_service : k => s.task_definition_arn }
}

output "ecs_task_exec_role_arns" {
  description = "Service to execution role ARN. A secret's resource policy names THIS role: it fetches the secret before the container starts."
  value       = { for k, s in module.ecs_service : k => s.task_exec_iam_role_arn }
}

output "database_endpoint" {
  description = "RDS endpoint, or null without a database. Services receive it as DATABASE_HOST / DATABASE_PORT / DATABASE_NAME."
  value       = one(module.rds[*].endpoint)
}

output "database_master_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials — reference it under services.<name>.secrets, never copy the value."
  value       = one(module.rds[*].master_user_secret_arn)
}

output "redis_endpoint" {
  description = "Redis primary endpoint, or null without a cache. Services receive it as REDIS_HOST / REDIS_PORT."
  value       = one(module.elasticache[*].primary_endpoint_address)
}

output "sns_alarm_topic_arn" {
  description = "Topic every alarm in this stack publishes to."
  value       = module.cloudwatch.sns_topic_arn
}
