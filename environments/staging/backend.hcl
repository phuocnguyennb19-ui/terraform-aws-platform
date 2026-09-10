# Remote state for the staging environment.
#
# Replace the bucket and dynamodb_table with the ones in your account, then:
#   terraform init -reconfigure -backend-config=backend.hcl
#
# The state bucket and lock table are chicken-and-egg infrastructure: they have
# to exist before the first apply. Create them once, out of band, with
# versioning and encryption on — `make bootstrap-state ENV=staging` prints the
# commands.

bucket = "REPLACE-ME-terraform-state-staging"
key    = "platform/staging/terraform.tfstate"
region = "ap-southeast-1"

encrypt = true

# STATE LOCKING
#
# Without a lock, two concurrent applies interleave their writes and corrupt the
# state file. There is no recovery from that beyond restoring a previous version
# and reconciling by hand.
#
# On Terraform 1.5.7 (this repo's pinned CLI) locking requires a DynamoDB table
# with a partition key named LockID:
dynamodb_table = "REPLACE-ME-terraform-locks"

# On Terraform >= 1.10 the S3 backend locks natively and the DynamoDB table can
# be dropped. Swap the line above for the line below once the CLI floor moves:
# use_lockfile = true
