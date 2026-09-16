locals {
  top_level_keys = ["environment", "account_id", "region", "platform", "dns", "services", "database", "cache", "kubernetes", "chart", "secret_store", "eks"]
  service_keys   = ["image", "size", "replicas", "platform", "public", "health_check", "env", "secrets", "autoscaling"]
  size_names     = ["small", "medium", "large"]
  platform_types = ["ecs", "eks"]
  runtime_in_use = { ecs = local.is_ecs, eks = local.is_eks }

  # Keys one runtime implements and the other does not yet — rejected there, never ignored.
  platform_only_keys = {
    ecs = {
      dns        = "dns publishes public services, which need platform ecs."
      kubernetes = "kubernetes adds a cluster beside ECS; platform eks always builds one."
    }
    eks = {
      eks          = "eks configures the cluster of platform eks."
      chart        = "chart pins the Helm chart the eks deploy job installs."
      secret_store = "secret_store names the External Secrets store eks pulls secrets from; ecs reads Secrets Manager and SSM directly."
    }
  }

  config_errors = compact(flatten([
    can(keys(local.config)) ? "" : "terraform/${local.config_file} is empty, not a mapping, or not valid YAML.\n    Quote any value that ends in \":\" or contains \": \" — a secret ARN with a JSON-key suffix (…:key::) is the usual one.",

    [for k in try(keys(local.config), []) :
      contains(local.top_level_keys, k) ? "" : "Unknown key \"${k}\".\n    Supported: ${join(", ", local.top_level_keys)}"
    ],

    try(local.config.environment, null) == var.environment ? "" : "environment is ${jsonencode(try(local.config.environment, null))}, but this file is terraform/${local.config_file} — they must match.",

    can(regex("^[0-9]{12}$", local.account_id)) ? "" : "account_id must be the 12-digit AWS account ID, in quotes (got ${jsonencode(try(local.config.account_id, null))}).",

    can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", local.region)) ? "" : "region must be an AWS region such as ap-southeast-1 (got ${jsonencode(try(local.config.region, null))}).",

    [for k in try(keys(local.config.platform), []) :
      k == "type" ? "" : "Unknown key platform.${k}.\n    Supported: type"
    ],
    contains(local.platform_types, local.platform) ? "" : "platform.type must be ecs or eks (got ${jsonencode(try(local.config.platform.type, null))}).",

    # Keyed on the runtimes this config actually uses, not on platform.type: an environment that
    # runs both needs both sets of keys.
    [for p, ks in local.platform_only_keys : [
      for k, why in ks : contains(local.platform_types, local.platform) && !lookup(local.runtime_in_use, p, false) && try(local.config[k], null) != null ? "${k} applies to platform ${p}, and no service here runs on ${p}: ${why}" : ""
    ]],

    [for k in try(keys(local.config.dns), []) :
      k == "domain" ? "" : "Unknown key dns.${k}.\n    Supported: domain"
    ],
    local.dns_domain == null || can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", local.dns_domain)) ? "" : "dns.domain must be a domain name such as example.com (got ${jsonencode(local.dns_domain)}).",

    try(local.config.services, null) == null || can(keys(local.config.services)) ? "" : "services must be a mapping of service name to settings.",

    [for name in local.service_names : [
      can(regex("^[a-z][a-z0-9-]{0,14}$", name)) ? "" : "Invalid service name \"${name}\".\n    Use 1-15 lowercase letters, digits or hyphens, starting with a letter.",

      can(keys(local.config.services[name])) ? "" : "services.${name} needs at least an image.",

      [for k in try(keys(local.config.services[name]), []) :
        contains(local.service_keys, k) ? "" : "Unknown key services.${name}.${k}.\n    Supported: ${join(", ", local.service_keys)}"
      ],

      can(regex("^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]+$", local.services[name].image)) && !endswith(local.services[name].image, ":latest") ? "" : "Invalid services.${name}.image: ${jsonencode(try(local.config.services[name].image, null))}\n    Expected <repository>:<tag> (or a full registry URI) with a fixed tag, never :latest.",

      contains(local.platform_types, local.placement[name]) ? "" : "Invalid services.${name}.platform: ${jsonencode(try(local.config.services[name].platform, null))}\n    Supported values: ${join(", ", local.platform_types)}",

      contains(local.size_names, local.services[name].size) ? "" : "Invalid services.${name}.size: ${jsonencode(try(local.config.services[name].size, null))}\n    Supported values:\n    - small\n    - medium\n    - large",

      try(local.config.services[name].replicas, null) == null || try(floor(local.config.services[name].replicas) == local.config.services[name].replicas && local.config.services[name].replicas >= 1, false) ? "" : "Invalid services.${name}.replicas: ${jsonencode(try(local.config.services[name].replicas, null))}\n    Must be a whole number, 1 or more.",

      try(local.config.services[name].public, null) == null || try(contains([true, false], local.config.services[name].public), false) ? "" : "Invalid services.${name}.public: ${jsonencode(try(local.config.services[name].public, null))}\n    Must be true or false.",
      contains(local.eks_services, name) && local.services[name].public ? "services.${name}.public is not available on platform eks yet: publishing a service needs the AWS Load Balancer Controller." : "",

      startswith(local.services[name].health_check, "/") ? "" : "Invalid services.${name}.health_check: ${jsonencode(local.services[name].health_check)}\n    Must be a path such as /healthz.",

      try(local.config.services[name].env, null) == null || can({ for k, v in local.config.services[name].env : k => tostring(v) }) ? "" : "services.${name}.env must be a mapping of NAME: value.",

      [for k, v in local.services[name].env : [
        can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) ? "" : "Invalid environment variable name services.${name}.env.${k}.",
        can(regex("(?i)(password|secret|token|private_key)", k)) ? "services.${name}.env.${k} looks like a credential.\n    Move it to services.${name}.secrets as a Secrets Manager or SSM ARN — config.yaml never holds secret values." : "",
      ]],

      try(local.config.services[name].secrets, null) == null || can({ for k, v in local.config.services[name].secrets : k => tostring(v) }) ? "" : "services.${name}.secrets must be a mapping of NAME: arn.",
      contains(local.eks_services, name) && try(local.config.services[name].secrets, null) != null && local.secret_provider == "" ? "services.${name}.secrets needs a store to pull from: set secret_store.provider to aws or vault." : "",

      [for k, v in local.services[name].secrets : [
        can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) ? "" : "Invalid secret name services.${name}.secrets.${k}.",
        contains(local.eks_services, name) || can(regex("^arn:aws:(secretsmanager|ssm):", v)) ? "" : "services.${name}.secrets.${k} must be a Secrets Manager or SSM parameter ARN, not a value.",
        !contains(local.eks_services, name) || length(split("#", v)) <= 2 ? "" : "Invalid services.${name}.secrets.${k}: ${jsonencode(v)}\n    Expected <key> or <key>#<property> — one # at most.",
        !contains(local.eks_services, name) || trimspace(split("#", v)[0]) != "" ? "" : "services.${name}.secrets.${k} needs a key before the #.",
        !contains(local.eks_services, name) || local.secret_provider != "vault" || !startswith(v, "arn:aws:") ? "" : "services.${name}.secrets.${k} is an AWS ARN, but secret_store.provider is vault — use the KV path, such as platform/${name}#${lower(k)}.",
      ]],

      [for k in try(keys(local.config.services[name].autoscaling), []) :
        contains(["min", "max"], k) ? "" : "Unknown key services.${name}.autoscaling.${k}.\n    Supported: min, max"
      ],
      !local.services[name].autoscaling || (local.services[name].min >= 1 && local.services[name].max >= local.services[name].min) ? "" : "Invalid services.${name}.autoscaling: needs max, with 1 <= min <= max (min defaults to replicas).",
    ]],

    length(local.public_services) > 1 && !local.dns_enabled ? "More than one public service (${join(", ", keys(local.public_services))}) needs dns.domain — each is published as <service>.<domain>." : "",

    [for k in try(keys(local.config.chart), []) :
      contains(["repository", "name", "version"], k) ? "" : "Unknown key chart.${k}.\n    Supported: repository, name, version"
    ],
    !local.is_eks || local.chart.registry_host != "" ? "" : "chart.repository must be an OCI registry path such as oci://111122223333.dkr.ecr.ap-southeast-1.amazonaws.com/charts (got ${jsonencode(try(local.config.chart.repository, null))}).",
    !local.is_eks || can(regex("^[a-z0-9][a-z0-9-]*$", local.chart.name)) ? "" : "chart.name must be the chart's name, such as application (got ${jsonencode(try(local.config.chart.name, null))}).",
    !local.is_eks || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", local.chart.version)) ? "" : "chart.version must be an exact version such as 2.0.0, in quotes — never a range (got ${jsonencode(try(local.config.chart.version, null))}).",

    [for k in try(keys(local.config.secret_store), []) :
      contains(["provider", "name"], k) ? "" : "Unknown key secret_store.${k}.\n    Supported: provider, name"
    ],
    try(local.config.secret_store, null) == null || contains(["aws", "vault"], local.secret_provider) ? "" : "secret_store.provider must be aws or vault (got ${jsonencode(try(local.config.secret_store.provider, null))}).",
    try(local.config.secret_store, null) == null || can(regex("^[a-z0-9][a-z0-9-]*$", local.secret_store.name)) ? "" : "secret_store.name must be the ClusterSecretStore name, such as aws-secretsmanager (got ${jsonencode(local.secret_store.name)}).",

    [for k in try(keys(local.config.eks), []) :
      k == "access" ? "" : "Unknown key eks.${k}.\n    Supported: access"
    ],
    try(local.config.eks.access, null) == null || length(local.eks_access) == length(try(keys(local.config.eks.access), [0])) ? "" : "eks.access must be a mapping of name to { principal_arn, policy }.",
    [for name, a in local.eks_access : [
      [for k in try(keys(local.config.eks.access[name]), []) :
        contains(["principal_arn", "policy"], k) ? "" : "Unknown key eks.access.${name}.${k}.\n    Supported: principal_arn, policy"
      ],
      can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", a.principal_arn)) ? "" : "eks.access.${name}.principal_arn must be an IAM role ARN (got ${jsonencode(a.principal_arn)}).",
      contains(keys(local.access_policies), a.policy) ? "" : "Invalid eks.access.${name}.policy: ${jsonencode(a.policy)}\n    Supported values: ${join(", ", keys(local.access_policies))}",
    ]],

    [for block, allowed in { database = ["enabled", "size"], cache = ["enabled", "size"], kubernetes = ["enabled"] } : [
      [for k in try(keys(local.config[block]), []) :
        contains(allowed, k) ? "" : "Unknown key ${block}.${k}.\n    Supported: ${join(", ", allowed)}"
      ],
      try(local.config[block].enabled, null) == null || try(contains([true, false], local.config[block].enabled), false) ? "" : "Invalid ${block}.enabled: must be true or false.",
    ]],
    [for block in ["database", "cache"] :
      try(local.config[block].size, null) == null || try(contains(local.size_names, local.config[block].size), false) ? "" : "Invalid ${block}.size: ${jsonencode(local.config[block].size)}\n    Supported values:\n    - small\n    - medium\n    - large"
    ],
  ]))
}

resource "terraform_data" "config" {
  lifecycle {
    # Layer 1. The can() terms make the mapping a dependency, so a plan targeted at this resource —
    # the contract tests — evaluates it without planning any AWS resource.
    precondition {
      condition     = length(local.config_errors) == 0 && can(local.service_specs) && can(local.release_specs) && can(local.chart) && can(local.secret_store) && can(local.access_entries) && can(local.enabled)
      error_message = "terraform/${local.config_file} is invalid:\n\n${join("\n", [for e in local.config_errors : "  - ${e}"])}"
    }

    # Layer 2, checked only once the config is well-formed.
    precondition {
      condition     = length(local.config_errors) > 0 || length(local.policy_errors) == 0
      error_message = "terraform/${local.config_file} is not allowed in ${var.environment}:\n\n${join("\n", [for e in local.policy_errors : "  - ${e}"])}"
    }
  }
}
