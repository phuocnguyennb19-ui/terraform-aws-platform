# CANONICAL VERSION CONSTRAINTS
#
# This file is the single source of truth for the Terraform and provider
# versions this platform is built and tested against. It is copied VERBATIM into
# every root module that runs, because `required_providers` must be declared in
# the root module that actually runs and cannot be inherited:
#
#   ./                      the config-driven entry point CI runs from, mapping
#                           config.yaml onto the modules — see ./variables.tf
#   environments/<env>/     the tfvars-driven per-environment roots
#
# `make versions-check` diffs every copy against ./versions.tf and fails if they
# have drifted — comments included, because `make versions-sync` copies the whole
# file, not just the terraform block. Change ./versions.tf, then run
# `make versions-sync`.
#
# Why the AWS provider is capped below 6.0:
#   The upstream module set pinned by this platform (vpc 5.21.0, eks 20.37.2,
#   alb 9.17.0, rds 6.13.1, acm 5.2.0, ec2-instance 5.8.0, lambda 7.21.1,
#   ecs 5.11.4) is the
#   newest line that supports the 5.x provider. The 6.x provider requires the
#   next major of every one of those modules, which is a coordinated upgrade,
#   not a version bump.

terraform {
  required_version = ">= 1.5.7, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80.0, < 6.0.0"
    }

    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0, < 4.0.0"
    }
  }
}
