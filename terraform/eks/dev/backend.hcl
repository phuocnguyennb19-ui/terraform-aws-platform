bucket = "REPLACE-ME-terraform-state-dev"
key    = "eks/dev/terraform.tfstate"
region = "ap-southeast-1"

encrypt = true

dynamodb_table = "REPLACE-ME-terraform-locks"
