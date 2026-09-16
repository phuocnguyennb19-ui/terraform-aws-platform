# Every stack reads the same config.yaml through this module: one mapping, one validation, one
# policy layer. It creates no AWS resource, so each stack rejects a bad config before planning.
module "config" {
  source = "../modules/config"

  environment = var.environment
  config_path = var.config_path
  tags        = var.tags
}

locals {
  project            = module.config.project
  environment        = module.config.environment
  name_prefix        = module.config.name_prefix
  is_prod            = module.config.is_prod
  region             = module.config.region
  account_id         = module.config.account_id
  common_tags        = module.config.common_tags
  env                = module.config.env
  enabled            = module.config.enabled
  services           = module.config.services_on_eks
  release_specs      = module.config.release_specs
  chart              = module.config.chart
  secret_store       = module.config.secret_store
  access_entries     = module.config.access_entries
  eks_cluster_name   = module.config.eks_cluster_name
  eks_namespace      = module.config.eks_namespace
  kubernetes_version = module.config.kubernetes_version
  connection_env     = local.base.connection_env
}
