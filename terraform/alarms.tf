locals {
  rds_alarms = {
    rds-cpu = {
      alarm_description   = "RDS CPU above 80% for 10 minutes on ${local.name_prefix}"
      namespace           = "AWS/RDS"
      metric_name         = "CPUUtilization"
      dimensions          = { DBInstanceIdentifier = "${local.name_prefix}-postgres" }
      threshold           = 80
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 2
      severity            = "warning"
    }

    rds-free-storage = {
      alarm_description   = "RDS free storage below 10 GiB on ${local.name_prefix}"
      namespace           = "AWS/RDS"
      metric_name         = "FreeStorageSpace"
      dimensions          = { DBInstanceIdentifier = "${local.name_prefix}-postgres" }
      threshold           = 10737418240
      comparison_operator = "LessThanThreshold"
      evaluation_periods  = 1
      severity            = "critical"
    }

    rds-connections = {
      alarm_description   = "RDS connection count unusually high on ${local.name_prefix}"
      namespace           = "AWS/RDS"
      metric_name         = "DatabaseConnections"
      dimensions          = { DBInstanceIdentifier = "${local.name_prefix}-postgres" }
      threshold           = 200
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
      severity            = "warning"
    }
  }

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

  cache_alarms = {
    cache-evictions = {
      alarm_description   = "ElastiCache is evicting keys on ${local.name_prefix} — the working set no longer fits"
      namespace           = "AWS/ElastiCache"
      metric_name         = "Evictions"
      statistic           = "Sum"
      dimensions          = { ReplicationGroupId = "${local.name_prefix}-redis" }
      threshold           = 0
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
      treat_missing_data  = "notBreaching"
      severity            = "warning"
    }

    cache-cpu = {
      alarm_description   = "ElastiCache engine CPU above 75% on ${local.name_prefix}"
      namespace           = "AWS/ElastiCache"
      metric_name         = "EngineCPUUtilization"
      dimensions          = { ReplicationGroupId = "${local.name_prefix}-redis" }
      threshold           = 75
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
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
