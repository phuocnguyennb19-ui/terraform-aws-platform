# PROVIDER CONFIGURATION
#
# Configured only here. No module under modules/ declares a provider, which is
# what lets one module serve every environment and every region.
#
# Region and role both come from the config file, so CI passes one argument
# (-var config_file=...) and cannot accidentally apply a prod config into a dev
# account: the role that would let it is named in the same file as the resources.

provider "aws" {
  region = local.region

  # Assume a per-environment role rather than using long-lived keys. With this
  # set, the credential that runs Terraform needs nothing except permission to
  # assume this one role, and every API call is attributable to the environment.
  dynamic "assume_role" {
    for_each = local.assume_role_arn != null ? [1] : []

    content {
      role_arn     = local.assume_role_arn
      session_name = "terraform-${local.project}-${local.environment}"
    }
  }

  # Belt and braces with the explicit tags each module receives: default_tags
  # does not reach resources created by a nested provider and does not appear in
  # every plan diff, so neither mechanism is sufficient alone.
  default_tags {
    tags = {
      Project     = local.project
      Environment = local.environment
      ManagedBy   = "terraform"
    }
  }
}
