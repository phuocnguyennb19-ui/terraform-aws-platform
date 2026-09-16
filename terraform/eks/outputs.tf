output "environment" {
  description = "Environment this stack built."
  value       = local.environment
}

output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = one(module.eks[*].cluster_name)
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig entry for this cluster (needs an EKS access entry)."
  value       = one(module.eks[*].kubeconfig_command)
}

output "service_internal_urls" {
  description = "How one service calls another inside the cluster: http://<service>:8080."
  value       = { for name, s in local.release_specs : name => s.internal_url }
}

# CI's deploy job reads this after apply and runs helm upgrade --install of the pinned chart per
# release. connection_env comes from the base stack, so it is added here, not in the config module.
output "helm_deployment" {
  description = "What the deploy job installs: the pinned chart, the target cluster and namespace, and each service's Helm values."
  value = {
    platform     = local.enabled.eks ? "eks" : "none"
    region       = local.region
    cluster_name = one(module.eks[*].cluster_name)
    namespace    = local.eks_namespace
    chart        = local.chart
    releases = {
      for name, r in local.release_specs : name => merge(r.values, {
        env = merge(local.connection_env, r.values.env)
      })
    }
  }
}
