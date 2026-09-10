# REMOTE STATE
#
# Deliberately empty. Bucket, key, region and locking are supplied at init time
# from this directory's backend.hcl:
#
#   terraform init -reconfigure -backend-config=backend.hcl
#
# A committed bucket/key pair is how a dev apply ends up writing prod state, so
# the values live in a file that is per-environment and never shared.
#
# State holds resolved values in plaintext — RDS endpoints, generated
# identifiers, anything a resource returns. Treat the bucket as sensitive:
# encrypted, versioned, access-logged, and readable only by the roles that need
# it. See README "How Terraform state is managed".

terraform {
  backend "s3" {}
}
