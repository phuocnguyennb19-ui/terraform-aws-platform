# tflint — catches what `terraform validate` cannot: invalid instance types,
# deprecated syntax, unpinned module sources, undocumented variables.
#
#   tflint --init      # install the plugins first
#   make lint

config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # deep_check calls the AWS API to verify that instance types, AMIs and
  # similar actually exist. Off by default because it needs credentials; turn it
  # on in a CI job that has them.
  # deep_check = true
}

# Naming
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Every module source must be pinned. An unpinned source means today's plan and
# tomorrow's plan can differ with no change in this repository.
rule "terraform_module_pinned_source" {
  enabled = true
  style   = "flexible"
}

rule "terraform_module_version" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

# A variable or output without a description is one the next person has to read
# the implementation to understand.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_comment_syntax" {
  enabled = true
}
