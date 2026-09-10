# ===========================================================================
# LIBRARY ROOT INPUTS
#
# The root takes a PATH, not a pile of settings. Every value that describes an
# environment lives in that YAML file, which is owned by the application
# repository and copied into this clone by CI:
#
#   git clone --depth 1 --branch <pinned-tag> <this repo> tf
#   cp config/prod/api.yaml tf/config.yaml
#   cd tf && terraform init -backend-config=backend.hcl
#   terraform plan -var config_file=config.yaml
#
# The path is resolved as file("${path.cwd}/${var.config_file}"), which is
# relative to the directory Terraform RUNS FROM — the repository root. Running
# from anywhere else resolves it against the wrong directory and fails at plan.
#
# One config file is one Terraform state. A base stack (network, cluster, ALB)
# and an application stack (one ECS service) are two configs and two states, and
# the application stack locates the base through the `existing:` block by name
# and tag rather than by hardcoded ID.
# ===========================================================================

variable "config_file" {
  description = "Path to the environment config, relative to the directory Terraform is run from."
  type        = string
  default     = "config.yaml"

  validation {
    condition     = can(regex("\\.ya?ml$", var.config_file))
    error_message = "config_file must point at a .yml or .yaml file."
  }
}

variable "tags" {
  description = "Extra tags merged over the ones derived from global.tags in the config. Use it for values CI knows and the config does not — the commit SHA, the pipeline ID."
  type        = map(string)
  default     = {}
}
