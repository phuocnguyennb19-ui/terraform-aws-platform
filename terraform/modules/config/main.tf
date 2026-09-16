locals {
  # A fixture is read from inside this module; a real config from terraform/env/<env>/.
  config_file = var.config_path != null ? "modules/config/${var.config_path}" : "env/${var.environment}/config.yaml"
  config_path = var.config_path != null ? "${path.module}/${var.config_path}" : "${path.module}/../../env/${var.environment}/config.yaml"
  # try(): a YAML syntax error becomes a readable entry in config_errors instead of a crash.
  config = try(yamldecode(file(local.config_path)), null)

  project     = "platform"
  environment = var.environment
  name_prefix = "${local.project}-${local.environment}"
  is_prod     = local.environment == "prod"

  region     = try(tostring(local.config.region), "")
  account_id = try(tostring(local.config.account_id), "")

  platform = try(tostring(local.config.platform.type), "")

  # Placement is per service so one environment can run both runtimes while services move across.
  # platform.type is the default; services.<name>.platform overrides it.
  placement = {
    for name in local.service_names : name => try(tostring(local.config.services[name].platform), local.platform)
  }
  ecs_services = toset([for name, p in local.placement : name if p == "ecs"])
  eks_services = toset([for name, p in local.placement : name if p == "eks"])

  is_ecs = length(local.ecs_services) > 0 || local.platform == "ecs"
  is_eks = length(local.eks_services) > 0 || local.platform == "eks"

  service_port = 8080

  sizes = {
    service = {
      small  = { cpu = 256, memory = 512, requests = { cpu = "250m", memory = "512Mi" } }
      medium = { cpu = 512, memory = 1024, requests = { cpu = "500m", memory = "1Gi" } }
      large  = { cpu = 1024, memory = 2048, requests = { cpu = "1", memory = "2Gi" } }
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

  public_services = { for name, s in local.services : name => s if s.public && contains(local.ecs_services, name) }

  service_namespace = "${local.name_prefix}.internal"

  # From the config, not module.ecr: ecs-service drops null container fields, so an image unknown at plan makes the task definition's keys unknown too.
  service_images = {
    for name, s in local.services : name => strcontains(s.image, "/") ? s.image : "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/${s.image}"
  }

  # What each service becomes — sizes, image, scaling, secret access. No module outputs here, so
  # the contract tests can evaluate it without planning AWS resources.
  service_specs = {
    for name, s in local.services : name => {
      cpu           = lookup(local.sizes.service, s.size, local.sizes.service.small).cpu
      memory        = lookup(local.sizes.service, s.size, local.sizes.service.small).memory
      desired_count = s.replicas

      image = local.service_images[name]

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
    } if contains(local.ecs_services, name)
  }

  # One chart for every service, pinned to an exact version and promoted env by env. The chart is
  # helm-project's charts/application, published to an ECR chart registry — an artifact this
  # platform consumes, like a module tag or a container image. It is never vendored here.
  chart_repository    = try(tostring(local.config.chart.repository), "")
  chart_registry_host = try(regex("^oci://([^/]+)/", local.chart_repository)[0], "")
  chart_name          = try(tostring(local.config.chart.name), "")
  chart = {
    repository = local.chart_repository
    name       = local.chart_name
    version    = try(tostring(local.config.chart.version), "")
    # What helm pull takes, assembled once: CI never builds this reference itself.
    ref             = local.chart_repository == "" ? "" : "${local.chart_repository}/${local.chart_name}"
    registry_host   = local.chart_registry_host
    ecr_registry_id = try(regex("^([0-9]{12})\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com$", local.chart_registry_host)[0], null)
  }

  # Secrets on EKS are pulled by External Secrets from one ClusterSecretStore per environment.
  # The provider decides how a reference reads; nothing else changes, so a cluster off AWS uses the
  # same config with a Vault store.
  secret_store_defaults = {
    aws   = "aws-secretsmanager"
    vault = "vault"
  }
  secret_provider = try(tostring(local.config.secret_store.provider), "")
  secret_store = {
    provider = local.secret_provider
    name     = try(tostring(local.config.secret_store.name), lookup(local.secret_store_defaults, local.secret_provider, ""))
    kind     = "ClusterSecretStore"
  }

  ecs_cluster_name = "${local.name_prefix}-ecs"

  kubernetes_version = "1.31"
  eks_cluster_name   = "${local.name_prefix}-eks"
  eks_namespace      = local.project

  # Cluster-wide EKS access policies a config may grant. Cluster admin is never granted from
  # config: only the identity that creates the cluster (the CI apply role) holds it.
  access_policies = {
    view       = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    admin-view = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
    edit       = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
    admin      = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
  }

  eks_access = try({
    for k, v in local.config.eks.access : k => {
      principal_arn = try(tostring(v.principal_arn), "")
      policy        = try(tostring(v.policy), "")
    }
  }, {})

  access_entries = {
    for k, a in local.eks_access : k => {
      principal_arn = a.principal_arn
      policy_associations = {
        (a.policy) = {
          policy_arn   = lookup(local.access_policies, a.policy, "")
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # What each service becomes on EKS — the values of its Helm release. Terraform never creates the
  # release: CI's deploy job runs helm with these values after apply. The key names are the chart's
  # contract (charts/application in helm-project); its values.schema.json is the other half.
  release_specs = {
    for name, s in local.services : name => {
      internal_url = "http://${name}:${local.service_port}"

      values = {
        fullnameOverride = name

        image = {
          repository = try(regex("^(.+):([^:/]+)$", local.service_images[name])[0], "")
          tag        = try(regex("^(.+):([^:/]+)$", local.service_images[name])[1], "")
        }

        replicaCount = s.replicas

        # The chart defaults service.port to 80; both ends are 8080 so http://<name>:8080 resolves.
        service = {
          port       = local.service_port
          targetPort = local.service_port
        }

        resources = {
          requests = lookup(local.sizes.service, s.size, local.sizes.service.small).requests
          limits   = { memory = lookup(local.sizes.service, s.size, local.sizes.service.small).requests.memory }
        }

        # Liveness only asks whether the process listens, so a failing dependency takes pods out of
        # rotation without restarting them.
        probes = {
          readiness = { httpGet = { path = s.health_check, port = "http" }, periodSeconds = 10, failureThreshold = 3 }
          liveness  = { tcpSocket = { port = "http" }, periodSeconds = 20, failureThreshold = 3 }
        }

        autoscaling = {
          enabled     = s.autoscaling
          minReplicas = s.min
          maxReplicas = max(s.max, s.min)
        }

        # The chart rejects a PDB carrying both minAvailable and maxUnavailable.
        podDisruptionBudget = {
          enabled        = (s.autoscaling ? s.min : s.replicas) >= 2
          maxUnavailable = 1
        }

        # The chart's root filesystem is read-only; /tmp is the one writable path.
        extraVolumes      = [{ name = "tmp", emptyDir = {} }]
        extraVolumeMounts = [{ name = "tmp", mountPath = "/tmp" }]

        # <key> or <key>#<property>: on aws the key is a Secrets Manager name or ARN, on vault a KV
        # path. injectEnvFrom puts the resulting Secret on the pod as environment variables.
        externalSecret = {
          enabled = length(s.secrets) > 0
          # Pinned rather than left to the chart's v1beta1 default: the estate's ClusterSecretStores
          # are external-secrets.io/v1.
          apiVersion     = "external-secrets.io/v1"
          injectEnvFrom  = true
          secretStoreRef = { name = local.secret_store.name, kind = local.secret_store.kind }
          data = [
            for k, ref in s.secrets : {
              secretKey = k
              remoteRef = merge(
                { key = split("#", ref)[0] },
                { for property in slice(split("#", ref), 1, length(split("#", ref))) : "property" => property },
              )
            }
          ]
        }

        env = s.env
      }
    } if contains(local.eks_services, name)
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
    alb      = length(local.public_services) > 0
    ecs      = length(local.ecs_services) > 0
    eks      = length(local.eks_services) > 0 || local.kubernetes_enabled
    ecr      = length(local.ecr_repositories) > 0
    dns      = local.is_ecs && local.dns_enabled
    database = local.database_enabled
    cache    = local.cache_enabled
  }
}
