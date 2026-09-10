# ===========================================================================
# ALARM DEFINITIONS
#
# Declared unconditionally here and filtered where they are consumed in main.tf.
# Every one publishes to the cloudwatch module's SNS topic on both ALARM and OK,
# so a recovery is as visible as a failure.
#
# An alarm with no owner is noise. These are the ones that mean "a human must
# look now"; anything that is merely interesting belongs on a dashboard.
# ===========================================================================

locals {
  ecs_cluster_name = local.enabled.ecs_cluster ? "${local.name_prefix}-ecs" : try(local.existing.ecs_cluster.name, null)

  rds_alarms = {
    rds-cpu = {
      alarm_description   = "RDS CPU above 80% for 10 minutes on ${local.name_prefix}"
      namespace           = "AWS/RDS"
      metric_name         = "CPUUtilization"
      dimensions          = { DBInstanceIdentifier = local.rds_identifier }
      threshold           = 80
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 2
      severity            = "warning"
    }

    # 10 GiB in bytes. Storage autoscaling should act first; this fires when it
    # has not, which is the point at which the database is minutes from read-only.
    rds-free-storage = {
      alarm_description   = "RDS free storage below 10 GiB on ${local.name_prefix}"
      namespace           = "AWS/RDS"
      metric_name         = "FreeStorageSpace"
      dimensions          = { DBInstanceIdentifier = local.rds_identifier }
      threshold           = 10737418240
      comparison_operator = "LessThanThreshold"
      evaluation_periods  = 1
      severity            = "critical"
    }

    rds-connections = {
      alarm_description   = "RDS connection count unusually high on ${local.name_prefix}"
      namespace           = "AWS/RDS"
      metric_name         = "DatabaseConnections"
      dimensions          = { DBInstanceIdentifier = local.rds_identifier }
      threshold           = 200
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
      severity            = "warning"
    }
  }

  alb_alarms = {
    # ELB_5XX, not TARGET_5XX: this counts errors the load balancer generated
    # itself — no healthy target, or a target that never answered — rather than
    # errors the application returned deliberately.
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

  # ---- ECS ----------------------------------------------------------------
  #
  # Two alarms per service, and they answer different questions:
  #
  #   running-tasks — is the service actually running what it should be? This is
  #     the one that catches a task that cannot start at all: a bad image, a
  #     secret the execution role cannot read, a subnet with no route to ECR.
  #     Circuit breaker rolls a DEPLOYMENT back; nothing rolls back a task that
  #     starts crashing an hour later.
  #
  #   cpu — is it saturated? Only meaningful above the autoscaling target, which
  #     is why the threshold is 85 and not 70: at 70 the scaling policy is
  #     already acting, and alarming there pages a human to watch autoscaling
  #     work.
  #
  # Both are per service, keyed so the alarm name says which service broke.
  #
  # Built with concat([{}], ...) and a filtered for-expression rather than a
  # ternary: merge() with zero arguments is an error when there are no services,
  # and a ternary would have to unify the type of "{}" with the type of a map of
  # alarm objects, which Terraform refuses.
  ecs_alarms = merge(concat([{}], [
    for k, svc in local.ecs_services : {
      "ecs-${k}-running-tasks" = {
        alarm_description = "ECS service ${local.name_prefix}-${k} is running fewer tasks than its floor"
        namespace         = "AWS/ECS"
        metric_name       = "RunningTaskCount"
        statistic         = "Minimum"
        dimensions = {
          ClusterName = local.ecs_cluster_name
          ServiceName = "${local.name_prefix}-${k}"
        }
        threshold           = max(try(svc.autoscaling.min, 2), local.hardened.ecs_min_tasks)
        comparison_operator = "LessThanThreshold"
        evaluation_periods  = 2
        # "missing" rather than notBreaching: no data from a service that should
        # be reporting is itself the failure, not an absence of one.
        treat_missing_data = "missing"
        severity           = "critical"
      }

      "ecs-${k}-cpu" = {
        alarm_description = "ECS service ${local.name_prefix}-${k} CPU above 85% — above the autoscaling target, so scaling is not keeping up"
        namespace         = "AWS/ECS"
        metric_name       = "CPUUtilization"
        dimensions = {
          ClusterName = local.ecs_cluster_name
          ServiceName = "${local.name_prefix}-${k}"
        }
        threshold           = 85
        comparison_operator = "GreaterThanThreshold"
        evaluation_periods  = 3
        treat_missing_data  = "notBreaching"
        severity            = "warning"
      }
    } if local.ecs_cluster_name != null
  ])...)
}
