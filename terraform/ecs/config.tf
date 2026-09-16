# Every stack reads the same config.yaml through this module: one mapping, one validation, one
# policy layer. It creates no AWS resource, so each stack rejects a bad config before planning.
module "config" {
  source = "../modules/config"

  environment = var.environment
  config_path = var.config_path
  tags        = var.tags
}

locals {
  project           = module.config.project
  environment       = module.config.environment
  name_prefix       = module.config.name_prefix
  is_prod           = module.config.is_prod
  region            = module.config.region
  account_id        = module.config.account_id
  common_tags       = module.config.common_tags
  env               = module.config.env
  enabled           = module.config.enabled
  service_port      = module.config.service_port
  services          = module.config.services_on_ecs
  service_specs     = module.config.service_specs
  public_services   = module.config.public_services
  dns_domain        = module.config.dns_domain
  service_namespace = module.config.service_namespace
  ecs_cluster_name  = module.config.ecs_cluster_name
  connection_env    = local.base.connection_env
}
