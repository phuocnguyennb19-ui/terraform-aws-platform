bucket = "REPLACE-ME-terraform-state-staging"
key    = "platform/staging/terraform.tfstate"
region = "ap-southeast-1"

encrypt = true

dynamodb_table = "REPLACE-ME-terraform-locks"
