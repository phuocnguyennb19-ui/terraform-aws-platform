output "environment" {
  description = "Environment this stack built."
  value       = local.environment
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
  description = "How one service calls another privately, through ECS Service Connect: http://<service>:8080."
  value       = { for name, s in local.service_specs : name => s.internal_url }
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
