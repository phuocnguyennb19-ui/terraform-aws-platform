variable "environment" {
  description = "Which terraform/<environment>/config.yaml to deploy."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "config_path" {
  description = "Contract tests only: read this file (under tests/fixtures/, relative to terraform/) instead of <environment>/config.yaml. Deployments never set it, and the file must still declare the environment being planned."
  type        = string
  default     = null

  validation {
    condition     = var.config_path == null || can(regex("^tests/fixtures/[A-Za-z0-9_.-]+\\.ya?ml$", coalesce(var.config_path, "-")))
    error_message = "config_path is a test hook: it may only name a file under tests/fixtures/."
  }
}

variable "tags" {
  description = "Extra tags CI knows and the config does not — the commit SHA, the pipeline ID."
  type        = map(string)
  default     = {}
}
