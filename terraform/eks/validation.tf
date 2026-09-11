locals {
  top_level_keys = ["environment", "account_id", "region", "chart", "cluster", "services", "database", "cache"]
  service_keys   = ["image", "size", "replicas", "health_check", "env", "autoscaling"]
  size_names     = ["small", "medium", "large"]

  config_errors = compact(flatten([
    can(keys(local.config)) ? "" : "terraform/eks/${local.config_file} is empty, not a mapping, or not valid YAML.",

    [for k in try(keys(local.config), []) :
      contains(local.top_level_keys, k) ? "" : "Unknown key \"${k}\".\n    Supported: ${join(", ", local.top_level_keys)}"
    ],

    try(local.config.environment, null) == var.environment ? "" : "environment is ${jsonencode(try(local.config.environment, null))}, but this file is terraform/eks/${local.config_file} — they must match.",

    can(regex("^[0-9]{12}$", local.account_id)) ? "" : "account_id must be the 12-digit AWS account ID, in quotes (got ${jsonencode(try(local.config.account_id, null))}).",

    can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", local.region)) ? "" : "region must be an AWS region such as ap-southeast-1 (got ${jsonencode(try(local.config.region, null))}).",

    [for k in try(keys(local.config.chart), []) :
      contains(["repository", "name", "version"], k) ? "" : "Unknown key chart.${k}.\n    Supported: repository, name, version"
    ],
    local.chart.registry_host != "" ? "" : "chart.repository must be an OCI registry path such as oci://111122223333.dkr.ecr.ap-southeast-1.amazonaws.com/charts (got ${jsonencode(try(local.config.chart.repository, null))}).",
    can(regex("^[a-z0-9][a-z0-9-]*$", local.chart.name)) ? "" : "chart.name must be the chart's name, such as application (got ${jsonencode(try(local.config.chart.name, null))}).",
    can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", local.chart.version)) ? "" : "chart.version must be an exact version such as 2.0.0, in quotes — never a range (got ${jsonencode(try(local.config.chart.version, null))}).",

    [for k in try(keys(local.config.cluster), []) :
      k == "access" ? "" : "Unknown key cluster.${k}.\n    Supported: access"
    ],
    try(local.config.cluster.access, null) == null || length(local.cluster_access) == length(try(keys(local.config.cluster.access), [0])) ? "" : "cluster.access must be a mapping of name to { principal_arn, policy }.",
    [for name, a in local.cluster_access : [
      [for k in try(keys(local.config.cluster.access[name]), []) :
        contains(["principal_arn", "policy"], k) ? "" : "Unknown key cluster.access.${name}.${k}.\n    Supported: principal_arn, policy"
      ],
      can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", a.principal_arn)) ? "" : "cluster.access.${name}.principal_arn must be an IAM role ARN (got ${jsonencode(a.principal_arn)}).",
      contains(keys(local.access_policies), a.policy) ? "" : "Invalid cluster.access.${name}.policy: ${jsonencode(a.policy)}\n    Supported values: ${join(", ", keys(local.access_policies))}",
    ]],

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

      startswith(local.services[name].health_check, "/") ? "" : "Invalid services.${name}.health_check: ${jsonencode(local.services[name].health_check)}\n    Must be a path such as /healthz.",

      try(local.config.services[name].env, null) == null || can({ for k, v in local.config.services[name].env : k => tostring(v) }) ? "" : "services.${name}.env must be a mapping of NAME: value.",

      [for k, v in local.services[name].env : [
        can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) ? "" : "Invalid environment variable name services.${name}.env.${k}.",
        can(regex("(?i)(password|secret|token|private_key)", k)) ? "services.${name}.env.${k} looks like a credential.\n    config.yaml never holds secret values, and the Helm release stores env in plaintext." : "",
      ]],

      [for k in try(keys(local.config.services[name].autoscaling), []) :
        contains(["min", "max"], k) ? "" : "Unknown key services.${name}.autoscaling.${k}.\n    Supported: min, max"
      ],
      !local.services[name].autoscaling || (local.services[name].min >= 1 && local.services[name].max >= local.services[name].min) ? "" : "Invalid services.${name}.autoscaling: needs max, with 1 <= min <= max (min defaults to replicas).",
    ]],

    [for block in ["database", "cache"] : [
      [for k in try(keys(local.config[block]), []) :
        contains(["enabled", "size"], k) ? "" : "Unknown key ${block}.${k}.\n    Supported: enabled, size"
      ],
      try(local.config[block].enabled, null) == null || try(contains([true, false], local.config[block].enabled), false) ? "" : "Invalid ${block}.enabled: must be true or false.",
      try(local.config[block].size, null) == null || try(contains(local.size_names, local.config[block].size), false) ? "" : "Invalid ${block}.size: ${jsonencode(local.config[block].size)}\n    Supported values:\n    - small\n    - medium\n    - large",
    ]],
  ]))
}

resource "terraform_data" "config" {
  lifecycle {
    # Layer 1. The can() terms make the mapping a dependency, so a plan targeted at this resource —
    # the contract tests — evaluates it without planning any AWS resource.
    precondition {
      condition     = length(local.config_errors) == 0 && can(local.release_specs) && can(local.access_entries) && can(local.enabled)
      error_message = "terraform/eks/${local.config_file} is invalid:\n\n${join("\n", [for e in local.config_errors : "  - ${e}"])}"
    }

    # Layer 2, checked only once the config is well-formed.
    precondition {
      condition     = length(local.config_errors) > 0 || length(local.policy_errors) == 0
      error_message = "terraform/eks/${local.config_file} is not allowed in ${var.environment}:\n\n${join("\n", [for e in local.policy_errors : "  - ${e}"])}"
    }
  }
}
