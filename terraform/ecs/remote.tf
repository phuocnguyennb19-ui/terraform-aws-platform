# What base built. A runtime stack never creates a VPC, a key, a database or the alarm topic —
# it reads them here, so both runtimes share one foundation and one data layer.
data "terraform_remote_state" "base" {
  backend = "s3"

  config = {
    bucket = var.base_state_bucket
    key    = "platform/${var.environment}/base.tfstate"
    region = var.base_state_region
  }
}

locals {
  base = data.terraform_remote_state.base.outputs
}
