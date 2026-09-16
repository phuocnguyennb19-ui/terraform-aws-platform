locals {
  alb_alarms = {
    alb-5xx = {
      alarm_description   = "ALB returning 5xx from its own layer on ${local.name_prefix}"
      namespace           = "AWS/ApplicationELB"
      metric_name         = "HTTPCode_ELB_5XX_Count"
      statistic           = "Sum"
      dimensions          = { LoadBalancer = one(module.alb[*].arn_suffix) }
      threshold           = 10
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 2
      treat_missing_data  = "notBreaching"
      severity            = "critical"
    }

    alb-unhealthy-hosts = {
      alarm_description   = "ALB has unhealthy targets on ${local.name_prefix}"
      namespace           = "AWS/ApplicationELB"
      metric_name         = "UnHealthyHostCount"
      statistic           = "Maximum"
      dimensions          = { LoadBalancer = one(module.alb[*].arn_suffix) }
      threshold           = 0
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 2
      treat_missing_data  = "missing"
      severity            = "critical"
    }

    alb-target-latency = {
      alarm_description   = "ALB p99 target response time above 2s on ${local.name_prefix}"
      namespace           = "AWS/ApplicationELB"
      metric_name         = "TargetResponseTime"
      extended_statistic  = "p99"
      dimensions          = { LoadBalancer = one(module.alb[*].arn_suffix) }
      threshold           = 2
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
      treat_missing_data  = "notBreaching"
      severity            = "warning"
    }
  }

  # concat([{}], ...) keeps merge() valid when there are no services.
  ecs_alarms = merge(concat([{}], [
    for name, s in local.services : {
      "ecs-${name}-running-tasks" = {
        alarm_description = "ECS service ${local.name_prefix}-${name} is running fewer tasks than its floor"
        namespace         = "AWS/ECS"
        metric_name       = "RunningTaskCount"
        statistic         = "Minimum"
        dimensions = {
          ClusterName = local.ecs_cluster_name
          ServiceName = "${local.name_prefix}-${name}"
        }
        threshold           = s.autoscaling ? s.min : s.replicas
        comparison_operator = "LessThanThreshold"
        evaluation_periods  = 2
        treat_missing_data  = "missing"
        severity            = "critical"
      }

      "ecs-${name}-cpu" = {
        alarm_description = "ECS service ${local.name_prefix}-${name} CPU above 85%"
        namespace         = "AWS/ECS"
        metric_name       = "CPUUtilization"
        dimensions = {
          ClusterName = local.ecs_cluster_name
          ServiceName = "${local.name_prefix}-${name}"
        }
        threshold           = 85
        comparison_operator = "GreaterThanThreshold"
        evaluation_periods  = 3
        treat_missing_data  = "notBreaching"
        severity            = "warning"
      }
    }
  ])...)
}
