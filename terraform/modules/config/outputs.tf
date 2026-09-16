output "environment" {
  description = "Environment this config belongs to."
  value       = local.environment
}

output "platform" {
  description = "The environment's default runtime; services may be placed on the other one."
  value       = local.platform
}

output "project" {
  description = "Project name every resource is prefixed with."
  value       = local.project
}

output "name_prefix" {
  description = "Prefix every resource name in every stack is built from."
  value       = local.name_prefix
}

output "is_prod" {
  description = "Whether prod policy applies."
  value       = local.is_prod
}

output "region" {
  description = "AWS region from the config."
  value       = local.region
}

output "account_id" {
  description = "AWS account ID from the config, used to build image URIs and to pin the provider."
  value       = local.account_id
}

output "common_tags" {
  description = "Tags every resource in every stack carries."
  value       = local.common_tags
}

output "env" {
  description = "The environment's own settings — CIDR, AZs, NAT, retention, node groups, database and cache policy."
  value       = local.env
}

output "enabled" {
  description = "What this config asks each stack to build."
  value       = local.enabled
}

output "service_port" {
  description = "The one container port every service listens on."
  value       = local.service_port
}

output "services" {
  description = "Normalized services, before either runtime's mapping."
  value       = local.services
}

output "services_on_ecs" {
  description = "Normalized services placed on ecs."
  value       = { for k, v in local.services : k => v if contains(local.ecs_services, k) }
}

output "services_on_eks" {
  description = "Normalized services placed on eks."
  value       = { for k, v in local.services : k => v if contains(local.eks_services, k) }
}

output "placement" {
  description = "Service name to the runtime it runs on: ecs or eks."
  value       = local.placement
}

output "service_specs" {
  description = "Exact ECS inputs, for the services placed on ecs."
  value       = local.service_specs
}

output "release_specs" {
  description = "Helm values, for the services placed on eks."
  value       = local.release_specs
}

output "public_services" {
  description = "Services published through the ALB. ECS only."
  value       = local.public_services
}

output "ecr_repositories" {
  description = "Repository names to create, shared by both runtimes."
  value       = local.ecr_repositories
}

output "dns_domain" {
  description = "Zone public services are published under, or null."
  value       = local.dns_domain
}

output "service_namespace" {
  description = "Cloud Map namespace ECS Service Connect joins."
  value       = local.service_namespace
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = local.ecs_cluster_name
}

output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = local.eks_cluster_name
}

output "eks_namespace" {
  description = "Namespace every Helm release is installed into."
  value       = local.eks_namespace
}

output "kubernetes_version" {
  description = "Kubernetes minor version of the cluster."
  value       = local.kubernetes_version
}

output "access_entries" {
  description = "EKS access entries built from eks.access."
  value       = local.access_entries
}

output "chart" {
  description = "The pinned chart the eks deploy job installs."
  value       = local.chart
}

output "secret_store" {
  description = "Which External Secrets store eks pulls secrets from."
  value       = local.secret_store
}

output "database_size" {
  description = "RDS instance class and storage for the configured size."
  value       = local.database_size
}

output "cache_size" {
  description = "ElastiCache node type for the configured size."
  value       = local.cache_size
}

output "config_errors" {
  description = "Layer 1 — everything wrong with the config's shape. Empty when it is well-formed."
  value       = local.config_errors
}

output "policy_errors" {
  description = "Layer 2 — everything this environment does not allow. Empty when the config is allowed."
  value       = local.policy_errors
}
