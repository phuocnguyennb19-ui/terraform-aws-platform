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

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig entry for this cluster (needs an EKS access entry)."
  value       = module.eks.kubeconfig_command
}

output "namespace" {
  description = "Namespace every service release is installed into."
  value       = local.namespace
}

output "service_internal_urls" {
  description = "How one service calls another inside the cluster: http://<service>:8080."
  value       = { for name, s in local.release_specs : name => s.internal_url }
}

output "helm_release_versions" {
  description = "Service to deployed chart version and release revision — the revision a `helm rollback` returns to."
  value       = { for k, r in helm_release.service : k => { chart = r.version, revision = r.metadata[0].revision } }
}

output "ecr_repository_urls" {
  description = "Repository name to registry URL — what a CI build tags and pushes an image to."
  value       = try(module.ecr[0].repository_urls, {})
}

output "database_endpoint" {
  description = "RDS endpoint, or null without a database. Services receive it as DATABASE_HOST / DATABASE_PORT / DATABASE_NAME."
  value       = one(module.rds[*].endpoint)
}

output "database_master_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials — never copy the value into config."
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
