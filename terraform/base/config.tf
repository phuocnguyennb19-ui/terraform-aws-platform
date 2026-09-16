# Every stack reads the same config.yaml through this module: one mapping, one validation, one
# policy layer. It creates no AWS resource, so each stack rejects a bad config before planning.
module "config" {
  source = "../modules/config"

  environment = var.environment
  config_path = var.config_path
  tags        = var.tags
}

locals {
  project          = module.config.project
  environment      = module.config.environment
  name_prefix      = module.config.name_prefix
  is_prod          = module.config.is_prod
  region           = module.config.region
  account_id       = module.config.account_id
  common_tags      = module.config.common_tags
  env              = module.config.env
  enabled          = module.config.enabled
  service_port     = module.config.service_port
  ecr_repositories = module.config.ecr_repositories
  database_size    = module.config.database_size
  cache_size       = module.config.cache_size
}
