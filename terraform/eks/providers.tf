provider "aws" {
  region              = local.region
  allowed_account_ids = [local.account_id]

  default_tags {
    tags = {
      Project     = local.project
      Stack       = local.stack
      Environment = local.environment
      ManagedBy   = "terraform"
    }
  }
}

# Presigned locally — no call to EKS, so it works on the plan that creates the cluster.
data "aws_eks_cluster_auth" "this" {
  name = local.cluster_name
}

# Only for an ECR chart registry; any other OCI registry is pulled anonymously.
data "aws_ecr_authorization_token" "chart" {
  count       = local.chart.ecr_registry_id != null ? 1 : 0
  registry_id = local.chart.ecr_registry_id
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }

  dynamic "registry" {
    for_each = data.aws_ecr_authorization_token.chart
    content {
      url      = "oci://${local.chart.registry_host}"
      username = registry.value.user_name
      password = registry.value.password
    }
  }
}
