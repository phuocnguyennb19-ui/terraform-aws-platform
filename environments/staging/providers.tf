# PROVIDER CONFIGURATION
#
# Configured only here. No module under modules/ declares a provider, which is
# what lets one module serve every environment and every region.
#
# default_tags applies the common tag set to every taggable resource the
# provider creates, including ones a module forgets to tag. Modules still pass
# tags explicitly — default_tags does not reach resources created by a nested
# provider, and it does not show up in some plan diffs — so the two together are
# belt and braces rather than duplication.

provider "aws" {
  region = var.region

  # Assume a per-environment role rather than using long-lived keys. With this
  # set, the credential that runs Terraform needs nothing except permission to
  # assume this one role, and every API call is attributable to the environment.
  dynamic "assume_role" {
    for_each = var.assume_role_arn != null ? [1] : []

    content {
      role_arn     = var.assume_role_arn
      session_name = "terraform-${var.project}-${var.environment}"
    }
  }

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Owner       = var.owner
      CostCenter  = var.cost_center
      ManagedBy   = "terraform"
    }
  }
}
