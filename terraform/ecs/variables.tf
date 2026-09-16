variable "environment" {
  description = "Which terraform/env/<environment>/config.yaml to deploy."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "config_path" {
  description = "Contract tests only: a fixture under modules/config/tests/fixtures/. Deployments never set it."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags CI knows and the config does not — the commit SHA, the pipeline ID."
  type        = map(string)
  default     = {}
}

variable "base_state_bucket" {
  description = "Bucket holding the base stack's state — the same bucket as this stack's, from terraform/env/<env>/backend.hcl. CI passes it; a runtime stack cannot plan without reading what base built."
  type        = string
}

variable "base_state_region" {
  description = "Region of that bucket."
  type        = string
}
