locals {
  config_file = coalesce(var.config_path, "${var.environment}/config.yaml")
  # try(): a YAML syntax error becomes a readable entry in config_errors instead of a crash.
  config = try(yamldecode(file("${path.module}/${local.config_file}")), null)

  project     = "platform"
  environment = var.environment
  name_prefix = "${local.project}-${local.environment}"
  is_prod     = local.environment == "prod"

  region     = try(tostring(local.config.region), "")
  account_id = try(tostring(local.config.account_id), "")

  service_port = 8080

  sizes = {
    service = {
      small  = { cpu = 256, memory = 512 }
      medium = { cpu = 512, memory = 1024 }
      large  = { cpu = 1024, memory = 2048 }
    }
    database = {
      small  = { instance_class = "db.t4g.medium", allocated_storage = 20, max_allocated_storage = 100 }
      medium = { instance_class = "db.t4g.large", allocated_storage = 50, max_allocated_storage = 200 }
      large  = { instance_class = "db.r6g.xlarge", allocated_storage = 200, max_allocated_storage = 1000 }
    }
    cache = {
      small  = "cache.t4g.small"
      medium = "cache.t4g.medium"
      large  = "cache.r7g.large"
    }
  }

  environments = {
    dev = {
      cost_center               = "engineering-dev"
      default_replicas          = 1
      vpc_cidr                  = "10.10.0.0/16"
      az_count                  = 2
      pin_azs                   = false
      single_nat_gateway        = true
      flow_log_retention_days   = 7
      interface_endpoints       = []
      log_retention_days        = 7
      alb_access_logs_days      = 14
      ecr_untagged_expiry_days  = 3
      ecr_keep_tagged_count     = 20
      rds_multi_az              = false
      rds_backup_retention_days = 3
      cache_nodes               = 1
      eks_public_api            = true
      eks_public_api_cidrs      = ["203.0.113.0/24"]
      eks_node_groups = {
        general = { instance_types = ["t3.large"], capacity_type = "SPOT", min_size = 1, max_size = 3, desired_size = 2, disk_size = 50 }
      }
    }
    staging = {
      cost_center               = "engineering-staging"
      default_replicas          = 2
      vpc_cidr                  = "10.20.0.0/16"
      az_count                  = 3
      pin_azs                   = false
      single_nat_gateway        = false
      flow_log_retention_days   = 30
      interface_endpoints       = []
      log_retention_days        = 30
      alb_access_logs_days      = 30
      ecr_untagged_expiry_days  = 7
      ecr_keep_tagged_count     = 30
      rds_multi_az              = true
      rds_backup_retention_days = 7
      cache_nodes               = 2
      eks_public_api            = true
      eks_public_api_cidrs      = ["203.0.113.0/24"]
      eks_node_groups = {
        general = { instance_types = ["t3.large"], capacity_type = "ON_DEMAND", min_size = 2, max_size = 6, desired_size = 2, disk_size = 50, labels = { workload = "general" } }
        spot = {
          instance_types = ["t3.large", "t3a.large", "m5.large"], capacity_type = "SPOT", min_size = 0, max_size = 6, desired_size = 1, disk_size = 50
          labels         = { workload = "burstable" }
          taints         = { spot = { key = "capacity", value = "spot", effect = "NO_SCHEDULE" } }
        }
      }
    }
    prod = {
      cost_center               = "production"
      default_replicas          = 2
      vpc_cidr                  = "10.30.0.0/16"
      az_count                  = 3
      pin_azs                   = true
      single_nat_gateway        = false
      flow_log_retention_days   = 365
      interface_endpoints       = ["ecr.api", "ecr.dkr", "logs", "ssm", "ssmmessages", "ec2messages", "sts", "kms"]
      log_retention_days        = 365
      alb_access_logs_days      = 365
      ecr_untagged_expiry_days  = 14
      ecr_keep_tagged_count     = 100
      rds_multi_az              = true
      rds_backup_retention_days = 30
      cache_nodes               = 3
      eks_public_api            = false
      eks_public_api_cidrs      = []
      eks_node_groups = {
        general = { instance_types = ["m6i.xlarge"], capacity_type = "ON_DEMAND", min_size = 3, max_size = 12, desired_size = 3, disk_size = 100, labels = { workload = "general" } }
        spot = {
          instance_types = ["m6i.xlarge", "m6a.xlarge", "m5.xlarge"], capacity_type = "SPOT", min_size = 0, max_size = 20, desired_size = 2, disk_size = 100
          labels         = { workload = "burstable" }
          taints         = { spot = { key = "capacity", value = "spot", effect = "NO_SCHEDULE" } }
        }
      }
    }
  }

  env = local.environments[var.environment]

  common_tags = merge(
    {
      Project     = local.project
      Environment = local.environment
      Owner       = "platform-engineering"
      CostCenter  = local.env.cost_center
      ManagedBy   = "terraform"
      Repository  = "terraform-aws-platform"
    },
    var.tags,
  )

  dns_domain  = try(tostring(local.config.dns.domain), null)
  dns_enabled = local.dns_domain != null

  service_names = try(keys(local.config.services), [])

  services = {
    for name in local.service_names : name => {
      image        = try(tostring(local.config.services[name].image), "")
      size         = try(tostring(local.config.services[name].size), "small")
      replicas     = try(tonumber(local.config.services[name].replicas), local.env.default_replicas)
      public       = try(local.config.services[name].public == true, false)
      health_check = try(tostring(local.config.services[name].health_check), "/healthz")
      env          = try({ for k, v in local.config.services[name].env : k => tostring(v) }, {})
      secrets      = try({ for k, v in local.config.services[name].secrets : k => tostring(v) }, {})
      autoscaling  = try(local.config.services[name].autoscaling, null) != null
      min = try(
        tonumber(local.config.services[name].autoscaling.min),
        try(tonumber(local.config.services[name].replicas), local.env.default_replicas),
      )
      max = try(tonumber(local.config.services[name].autoscaling.max), 0)
    }
  }

  public_services = { for name, s in local.services : name => s if s.public }

  service_namespace = "${local.name_prefix}.internal"

  # What each service becomes — sizes, image, scaling, secret access. No module outputs here, so
  # the contract tests can evaluate it without planning AWS resources.
  service_specs = {
    for name, s in local.services : name => {
      cpu           = lookup(local.sizes.service, s.size, local.sizes.service.small).cpu
      memory        = lookup(local.sizes.service, s.size, local.sizes.service.small).memory
      desired_count = s.replicas

      # From the config, not module.ecr: ecs-service drops null container fields, so an image unknown at plan makes the task definition's keys unknown too.
      image = strcontains(s.image, "/") ? s.image : "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/${s.image}"

      public       = s.public
      health_check = s.health_check
      internal_url = "http://${name}:${local.service_port}"

      autoscaling = {
        enabled = s.autoscaling
        min     = s.min
        max     = max(s.max, s.min)
      }

      enable_execute_command = !local.is_prod

      env     = s.env
      secrets = s.secrets

      # The execution role reads a secret before the container starts; a JSON-key suffix is not part of the ARN it needs.
      task_exec_secret_arns    = distinct([for v in values(s.secrets) : join(":", slice(split(":", v), 0, 7)) if startswith(v, "arn:aws:secretsmanager:") && length(split(":", v)) >= 7])
      task_exec_ssm_param_arns = distinct([for v in values(s.secrets) : v if startswith(v, "arn:aws:ssm:")])
    }
  }

  ecr_repositories = toset([
    for s in local.services : split(":", s.image)[0] if s.image != "" && !strcontains(s.image, "/")
  ])

  database_enabled = try(local.config.database.enabled == true, false)
  database_size    = lookup(local.sizes.database, try(tostring(local.config.database.size), "small"), local.sizes.database.small)

  cache_enabled = try(local.config.cache.enabled == true, false)
  cache_size    = lookup(local.sizes.cache, try(tostring(local.config.cache.size), "small"), local.sizes.cache.small)

  kubernetes_enabled = try(local.config.kubernetes.enabled == true, false)

  enabled = {
    alb        = length(local.public_services) > 0
    ecs        = length(local.services) > 0
    ecr        = length(local.ecr_repositories) > 0
    dns        = local.dns_enabled
    database   = local.database_enabled
    cache      = local.cache_enabled
    kubernetes = local.kubernetes_enabled
  }
}
