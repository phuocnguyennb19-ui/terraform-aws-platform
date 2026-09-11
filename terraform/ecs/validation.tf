locals {
  top_level_keys = ["environment", "account_id", "region", "dns", "services", "database", "cache", "kubernetes"]
  service_keys   = ["image", "size", "replicas", "public", "health_check", "env", "secrets", "autoscaling"]
  size_names     = ["small", "medium", "large"]

  config_errors = compact(flatten([
    can(keys(local.config)) ? "" : "terraform/ecs/${local.config_file} is empty, not a mapping, or not valid YAML.\n    Quote any value that ends in \":\" or contains \": \" — a secret ARN with a JSON-key suffix (…:key::) is the usual one.",

    [for k in try(keys(local.config), []) :
      contains(local.top_level_keys, k) ? "" : "Unknown key \"${k}\".\n    Supported: ${join(", ", local.top_level_keys)}"
    ],

    try(local.config.environment, null) == var.environment ? "" : "environment is ${jsonencode(try(local.config.environment, null))}, but this file is terraform/ecs/${local.config_file} — they must match.",

    can(regex("^[0-9]{12}$", local.account_id)) ? "" : "account_id must be the 12-digit AWS account ID, in quotes (got ${jsonencode(try(local.config.account_id, null))}).",

    can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", local.region)) ? "" : "region must be an AWS region such as ap-southeast-1 (got ${jsonencode(try(local.config.region, null))}).",

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

      contains(local.size_names, local.services[name].size) ? "" : "Invalid services.${name}.size: ${jsonencode(try(local.config.services[name].size, null))}\n    Supported values:\n    - small\n    - medium\n    - large",

      try(local.config.services[name].replicas, null) == null || try(floor(local.config.services[name].replicas) == local.config.services[name].replicas && local.config.services[name].replicas >= 1, false) ? "" : "Invalid services.${name}.replicas: ${jsonencode(try(local.config.services[name].replicas, null))}\n    Must be a whole number, 1 or more.",

      try(local.config.services[name].public, null) == null || try(contains([true, false], local.config.services[name].public), false) ? "" : "Invalid services.${name}.public: ${jsonencode(try(local.config.services[name].public, null))}\n    Must be true or false.",

      startswith(local.services[name].health_check, "/") ? "" : "Invalid services.${name}.health_check: ${jsonencode(local.services[name].health_check)}\n    Must be a path such as /healthz.",

      try(local.config.services[name].env, null) == null || can({ for k, v in local.config.services[name].env : k => tostring(v) }) ? "" : "services.${name}.env must be a mapping of NAME: value.",

      [for k, v in local.services[name].env : [
        can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) ? "" : "Invalid environment variable name services.${name}.env.${k}.",
        can(regex("(?i)(password|secret|token|private_key)", k)) ? "services.${name}.env.${k} looks like a credential.\n    Move it to services.${name}.secrets as a Secrets Manager or SSM ARN — config.yaml never holds secret values." : "",
      ]],

      try(local.config.services[name].secrets, null) == null || can({ for k, v in local.config.services[name].secrets : k => tostring(v) }) ? "" : "services.${name}.secrets must be a mapping of NAME: arn.",

      [for k, v in local.services[name].secrets : [
        can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) ? "" : "Invalid secret name services.${name}.secrets.${k}.",
        can(regex("^arn:aws:(secretsmanager|ssm):", v)) ? "" : "services.${name}.secrets.${k} must be a Secrets Manager or SSM parameter ARN, not a value.",
      ]],

      [for k in try(keys(local.config.services[name].autoscaling), []) :
        contains(["min", "max"], k) ? "" : "Unknown key services.${name}.autoscaling.${k}.\n    Supported: min, max"
      ],
      !local.services[name].autoscaling || (local.services[name].min >= 1 && local.services[name].max >= local.services[name].min) ? "" : "Invalid services.${name}.autoscaling: needs max, with 1 <= min <= max (min defaults to replicas).",
    ]],

    length(local.public_services) > 1 && !local.dns_enabled ? "More than one public service (${join(", ", keys(local.public_services))}) needs dns.domain — each is published as <service>.<domain>." : "",

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
      condition     = length(local.config_errors) == 0 && can(local.service_specs) && can(local.enabled)
      error_message = "terraform/ecs/${local.config_file} is invalid:\n\n${join("\n", [for e in local.config_errors : "  - ${e}"])}"
    }

    # Layer 2, checked only once the config is well-formed.
    precondition {
      condition     = length(local.config_errors) > 0 || length(local.policy_errors) == 0
      error_message = "terraform/ecs/${local.config_file} is not allowed in ${var.environment}:\n\n${join("\n", [for e in local.policy_errors : "  - ${e}"])}"
    }
  }
}
