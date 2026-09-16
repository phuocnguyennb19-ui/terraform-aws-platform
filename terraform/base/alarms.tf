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
}
