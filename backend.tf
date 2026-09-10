# REMOTE STATE
#
# Deliberately empty. Bucket, key, region and locking are supplied at init time
# by the application repository's own backend.hcl, alongside its config.yaml:
#
#   terraform init -reconfigure -backend-config=backend.hcl
#
# A committed bucket/key pair is how a dev apply ends up writing prod state, so
# the values live with the config that names the environment, never here.
#
# One config file is one state key. A base stack and an application stack in the
# same environment are two different keys, because they have different blast
# radii and different change cadences.
#
# State holds resolved values in plaintext — RDS endpoints, generated
# identifiers, rendered container definitions. Treat the bucket as sensitive:
# encrypted, versioned, access-logged, readable only by the roles that need it.

terraform {
  backend "s3" {}
}
