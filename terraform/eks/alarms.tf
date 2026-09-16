locals {
  # Container Insights metrics, published by the amazon-cloudwatch-observability addon.
  eks_alarms = merge(concat([{}], [
    for name, s in local.services : {
      "eks-${name}-running-pods" = {
        alarm_description = "EKS service ${name} in ${local.eks_cluster_name} is running fewer pods than its floor"
        namespace         = "ContainerInsights"
        metric_name       = "service_number_of_running_pods"
        statistic         = "Minimum"
        dimensions = {
          ClusterName = local.eks_cluster_name
          Namespace   = local.eks_namespace
          Service     = name
        }
        threshold           = s.autoscaling ? s.min : s.replicas
        comparison_operator = "LessThanThreshold"
        evaluation_periods  = 2
        treat_missing_data  = "missing"
        severity            = "critical"
      }

      "eks-${name}-memory" = {
        alarm_description = "EKS service ${name} in ${local.eks_cluster_name} is above 90% of its memory limit — the next step is an OOM kill"
        namespace         = "ContainerInsights"
        metric_name       = "pod_memory_utilization_over_pod_limit"
        dimensions = {
          ClusterName = local.eks_cluster_name
          Namespace   = local.eks_namespace
          Service     = name
        }
        threshold           = 90
        comparison_operator = "GreaterThanThreshold"
        evaluation_periods  = 3
        treat_missing_data  = "notBreaching"
        severity            = "warning"
      }
    }
    ], [
    for c in [local.eks_cluster_name] : {
      eks-failed-nodes = {
        alarm_description   = "EKS cluster ${c} has worker nodes reporting a failed condition"
        namespace           = "ContainerInsights"
        metric_name         = "cluster_failed_node_count"
        statistic           = "Maximum"
        dimensions          = { ClusterName = c }
        threshold           = 0
        comparison_operator = "GreaterThanThreshold"
        evaluation_periods  = 2
        treat_missing_data  = "notBreaching"
        severity            = "critical"
      }

      eks-node-cpu = {
        alarm_description   = "EKS cluster ${c} nodes above 80% CPU — pods will queue as Pending"
        namespace           = "ContainerInsights"
        metric_name         = "node_cpu_utilization"
        dimensions          = { ClusterName = c }
        threshold           = 80
        comparison_operator = "GreaterThanThreshold"
        evaluation_periods  = 3
        treat_missing_data  = "notBreaching"
        severity            = "warning"
      }
    }
  ])...)
}
