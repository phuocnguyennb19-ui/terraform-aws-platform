# The state key is not here: each stack has its own. CI passes
# -backend-config="key=platform/<env>/<stack>.tfstate".
bucket = "REPLACE-ME-terraform-state-staging"
region = "ap-southeast-1"

encrypt = true

dynamodb_table = "REPLACE-ME-terraform-locks"
