locals {
  # Layer 2 — is a well-formed config allowed in this environment? Environment policy lives here
  # and in local.environments, never in config.yaml: a developer cannot opt out of it.
  policy_errors = compact(flatten([
    [for name, s in local.services :
      local.is_prod && s.replicas < 2 ? "services.${name}.replicas is ${s.replicas}; prod runs at least 2 replicas." : ""
    ],
    [for name, s in local.services :
      local.is_prod && s.autoscaling && s.min < 2 ? "services.${name}.autoscaling.min is ${s.min}; prod keeps at least 2 pods running." : ""
    ],
    [for name, a in local.cluster_access :
      local.is_prod && contains(["edit", "admin"], a.policy) ? "cluster.access.${name}.policy is ${a.policy}; prod grants view or admin-view from config — changes go through CI." : ""
    ],
  ]))
}
