bucket = "REPLACE-ME-terraform-state-prod"
key    = "platform/prod/terraform.tfstate"
region = "ap-southeast-1"

encrypt = true

dynamodb_table = "REPLACE-ME-terraform-locks"
