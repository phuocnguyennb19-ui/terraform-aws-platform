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
