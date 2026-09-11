locals {
  config_file = coalesce(var.config_path, "${var.environment}/config.yaml")
  # try(): a YAML syntax error becomes a readable entry in config_errors instead of a crash.
  config = try(yamldecode(file("${path.module}/${local.config_file}")), null)

  # Every name carries the stack, so this stack and terraform/ecs can share an account.
  project      = "platform"
  stack        = "eks"
  environment  = var.environment
  name_prefix  = "${local.project}-${local.stack}-${local.environment}"
  cluster_name = local.name_prefix
  is_prod      = local.environment == "prod"

  region     = try(tostring(local.config.region), "")
  account_id = try(tostring(local.config.account_id), "")

  kubernetes_version = "1.31"
  namespace          = local.project
  service_port       = 8080

  sizes = {
    service = {
      small  = { cpu = "250m", memory = "512Mi" }
      medium = { cpu = "500m", memory = "1Gi" }
      large  = { cpu = "1", memory = "2Gi" }
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
      vpc_cidr                  = "10.11.0.0/16"
      az_count                  = 2
      pin_azs                   = false
      single_nat_gateway        = true
      flow_log_retention_days   = 7
      interface_endpoints       = []
      log_retention_days        = 7
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
      vpc_cidr                  = "10.21.0.0/16"
      az_count                  = 3
      pin_azs                   = false
      single_nat_gateway        = false
      flow_log_retention_days   = 30
      interface_endpoints       = []
      log_retention_days        = 30
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
      vpc_cidr                  = "10.31.0.0/16"
      az_count                  = 3
      pin_azs                   = true
      single_nat_gateway        = false
      flow_log_retention_days   = 365
      interface_endpoints       = ["ecr.api", "ecr.dkr", "logs", "ssm", "ssmmessages", "ec2messages", "sts", "kms"]
      log_retention_days        = 365
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
      Stack       = local.stack
      Environment = local.environment
      Owner       = "platform-engineering"
      CostCenter  = local.env.cost_center
      ManagedBy   = "terraform"
      Repository  = "terraform-aws-platform"
    },
    var.tags,
  )

  # One chart for every service, pinned to an exact version and promoted env by env.
  chart_repository    = try(tostring(local.config.chart.repository), "")
  chart_registry_host = try(regex("^oci://([^/]+)/", local.chart_repository)[0], "")
  chart = {
    repository      = local.chart_repository
    name            = try(tostring(local.config.chart.name), "")
    version         = try(tostring(local.config.chart.version), "")
    registry_host   = local.chart_registry_host
    ecr_registry_id = try(regex("^([0-9]{12})\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com$", local.chart_registry_host)[0], null)
  }

  # Cluster-wide EKS access policies a config may grant. Cluster admin is never granted from
  # config: only the identity that creates the cluster (the CI apply role) holds it.
  access_policies = {
    view       = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    admin-view = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
    edit       = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
    admin      = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
  }

  cluster_access = try({
    for k, v in local.config.cluster.access : k => {
      principal_arn = try(tostring(v.principal_arn), "")
      policy        = try(tostring(v.policy), "")
    }
  }, {})

  access_entries = {
    for k, a in local.cluster_access : k => {
      principal_arn = a.principal_arn
      policy_associations = {
        (a.policy) = {
          policy_arn   = lookup(local.access_policies, a.policy, "")
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  service_names = try(keys(local.config.services), [])

  services = {
    for name in local.service_names : name => {
      image        = try(tostring(local.config.services[name].image), "")
      size         = try(tostring(local.config.services[name].size), "small")
      replicas     = try(tonumber(local.config.services[name].replicas), local.env.default_replicas)
      health_check = try(tostring(local.config.services[name].health_check), "/healthz")
      env          = try({ for k, v in local.config.services[name].env : k => tostring(v) }, {})
      autoscaling  = try(local.config.services[name].autoscaling, null) != null
      min = try(
        tonumber(local.config.services[name].autoscaling.min),
        try(tonumber(local.config.services[name].replicas), local.env.default_replicas),
      )
      max = try(tonumber(local.config.services[name].autoscaling.max), 0)
    }
  }

  ecr_prefix = local.stack

  # A short name is this account's ECR, under this stack's prefix.
  service_images = {
    for name, s in local.services : name => strcontains(s.image, "/") ? s.image : "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/${local.ecr_prefix}/${s.image}"
  }

  # What each service becomes — the Helm values of its release. No module outputs here, so the
  # contract tests can evaluate it without planning AWS resources; main.tf adds connection env.
  release_specs = {
    for name, s in local.services : name => {
      image = local.service_images[name]

      # Every release shares one namespace, so the Service name alone resolves — as on ECS.
      internal_url = "http://${name}:${local.service_port}"

      values = {
        fullnameOverride = name

        image = {
          repository = try(regex("^(.+):([^:/]+)$", local.service_images[name])[0], "")
          tag        = try(regex("^(.+):([^:/]+)$", local.service_images[name])[1], "")
        }

        replicaCount = s.replicas

        service = {
          port       = local.service_port
          targetPort = local.service_port
        }

        resources = {
          requests = lookup(local.sizes.service, s.size, local.sizes.service.small)
          limits   = { memory = lookup(local.sizes.service, s.size, local.sizes.service.small).memory }
        }

        # Readiness follows the app's health check; liveness only asks whether the process
        # listens, so a failing dependency takes pods out of rotation without restarting them.
        probes = {
          readiness = { httpGet = { path = s.health_check, port = "http" }, periodSeconds = 10, failureThreshold = 3 }
          liveness  = { tcpSocket = { port = "http" }, periodSeconds = 20, failureThreshold = 3 }
        }

        autoscaling = {
          enabled     = s.autoscaling
          minReplicas = s.min
          maxReplicas = max(s.max, s.min)
        }

        podDisruptionBudget = {
          enabled        = (s.autoscaling ? s.min : s.replicas) >= 2
          maxUnavailable = 1
        }

        # The chart's root filesystem is read-only; /tmp is the one writable path.
        extraVolumes      = [{ name = "tmp", emptyDir = {} }]
        extraVolumeMounts = [{ name = "tmp", mountPath = "/tmp" }]
      }
    }
  }

  ecr_repositories = toset([
    for s in local.services : split(":", s.image)[0] if s.image != "" && !strcontains(s.image, "/")
  ])

  database_enabled = try(local.config.database.enabled == true, false)
  database_size    = lookup(local.sizes.database, try(tostring(local.config.database.size), "small"), local.sizes.database.small)

  cache_enabled = try(local.config.cache.enabled == true, false)
  cache_size    = lookup(local.sizes.cache, try(tostring(local.config.cache.size), "small"), local.sizes.cache.small)

  enabled = {
    ecr      = length(local.ecr_repositories) > 0
    database = local.database_enabled
    cache    = local.cache_enabled
  }
}
