data "aws_caller_identity" "current" {}

module "cloudwatch" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/cloudwatch?ref=v2.0.0"

  name = "${local.name_prefix}-ecs"

  create_sns_topic = false
  sns_topic_arn    = local.base.sns_topic_arn

  default_log_kms_key_arn = local.base.kms.logs

  # for-expressions, not ternaries: a ternary's branches must share one object type.
  metric_alarms = merge(
    { for k, v in local.alb_alarms : k => v if local.enabled.alb },
    local.ecs_alarms,
  )

  tags = local.common_tags
}

module "route53" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/route53?ref=v2.0.0"
  count  = local.enabled.dns ? 1 : 0

  zone_name   = local.dns_domain
  create_zone = false

  tags = local.common_tags
}

module "acm" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/acm?ref=v2.0.0"
  count  = local.enabled.dns && local.enabled.alb ? 1 : 0

  domain_name = "*.${local.dns_domain}"
  zone_id     = one(module.route53[*].zone_id)

  tags = local.common_tags
}

module "alb" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/alb?ref=v2.0.0"
  count  = local.enabled.alb ? 1 : 0

  name               = local.name_prefix
  vpc_id             = local.base.vpc_id
  subnet_ids         = local.base.public_subnet_ids
  security_group_ids = compact([local.base.security_group_ids.alb])
  internal           = false

  # Mirrors the acm count: the certificate ARN is unknown until apply.
  enable_https    = local.enabled.dns
  certificate_arn = one(module.acm[*].certificate_arn)

  target_groups = {
    for name, s in local.public_services : name => {
      port        = local.service_port
      protocol    = "HTTP"
      target_type = "ip"
      health_check = {
        path    = s.health_check
        matcher = "200"
      }
    }
  }

  default_target_group_key = try(sort(keys(local.public_services))[0], null)

  listener_rules = local.enabled.dns ? {
    for i, name in sort(keys(local.public_services)) : name => {
      priority         = (i + 1) * 10
      target_group_key = name
      host_headers     = ["${name}.${local.dns_domain}"]
    }
  } : {}

  enable_deletion_protection = local.is_prod
  enable_access_logs         = true
  access_logs_retention_days = local.env.alb_access_logs_days

  tags = local.common_tags
}

# Outside the route53 module: route53 -> acm -> alb -> these records would otherwise be a cycle.

resource "aws_route53_record" "service" {
  for_each = local.enabled.dns ? local.public_services : {}

  zone_id = module.route53[0].zone_id
  name    = "${each.key}.${local.dns_domain}"
  type    = "A"

  alias {
    name                   = module.alb[0].dns_name
    zone_id                = module.alb[0].zone_id
    evaluate_target_health = true
  }
}

module "ecs_cluster" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/ecs-cluster?ref=v2.0.0"
  count  = local.enabled.ecs ? 1 : 0

  cluster_name = local.ecs_cluster_name

  # Private service-to-service network: every service joins it through Service Connect.
  service_connect_namespace_name = local.service_namespace

  log_retention_days          = local.env.log_retention_days
  log_kms_key_arn             = local.base.kms.logs
  execute_command_kms_key_arn = local.base.kms.secrets

  tags = local.common_tags
}

module "ecs_service" {
  source   = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/ecs-service?ref=v2.0.0"
  for_each = local.service_specs

  name        = "${local.name_prefix}-${each.key}"
  cluster_arn = module.ecs_cluster[0].arn

  subnet_ids         = local.base.private_subnet_ids
  security_group_ids = compact([local.base.security_group_ids.ecs])

  cpu    = each.value.cpu
  memory = each.value.memory

  containers = {
    app = {
      image         = each.value.image
      port_mappings = [{ containerPort = local.service_port, name = "http" }]
      environment   = [for k, v in merge(local.connection_env, each.value.env) : { name = k, value = v }]
      secrets       = [for k, v in each.value.secrets : { name = k, valueFrom = v }]
    }
  }

  log_retention_days = local.env.log_retention_days
  log_kms_key_arn    = local.base.kms.logs

  desired_count          = each.value.desired_count
  enable_execute_command = each.value.enable_execute_command

  enable_load_balancer         = each.value.public
  target_group_arn             = each.value.public ? try(module.alb[0].target_group_arns[each.key], null) : null
  load_balancer_container_name = each.value.public ? "app" : null
  load_balancer_container_port = each.value.public ? local.service_port : null

  service_connect = {
    namespace = module.ecs_cluster[0].service_connect_namespace_arn
    port_name = "http"
    dns_name  = each.key
    port      = local.service_port
  }

  enable_autoscaling       = each.value.autoscaling.enabled
  autoscaling_min_capacity = each.value.autoscaling.min
  autoscaling_max_capacity = each.value.autoscaling.max

  task_exec_secret_arns    = each.value.task_exec_secret_arns
  task_exec_ssm_param_arns = each.value.task_exec_ssm_param_arns

  tags = merge(local.common_tags, { Service = each.key })
}

