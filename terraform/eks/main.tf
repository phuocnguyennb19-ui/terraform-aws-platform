data "aws_caller_identity" "current" {}

module "cloudwatch" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/cloudwatch?ref=v2.0.0"

  name = "${local.name_prefix}-eks"

  create_sns_topic = false
  sns_topic_arn    = local.base.sns_topic_arn

  default_log_kms_key_arn = local.base.kms.logs

  metric_alarms = local.eks_alarms

  tags = local.common_tags
}

module "eks" {
  source = "git::https://github.com/phuocnguyennb19-ui/terraform-module.git//modules/eks?ref=v2.0.0"
  count  = local.enabled.eks ? 1 : 0

  cluster_name       = local.eks_cluster_name
  kubernetes_version = local.kubernetes_version

  vpc_id     = local.base.vpc_id
  subnet_ids = local.base.private_subnet_ids

  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = local.env.eks_public_api
  cluster_endpoint_public_access_cidrs = local.env.eks_public_api_cidrs

  cluster_security_group_ids = compact([local.base.security_group_ids.eks_cluster])
  node_security_group_ids    = compact([local.base.security_group_ids.eks_node])

  node_groups = local.env.eks_node_groups

  access_entries = local.access_entries

  # The module defaults, plus what platform eks relies on: metrics-server feeds the HPA, the
  # CloudWatch addon ships container logs and Container Insights metrics (alarms.tf). The EBS CSI
  # controller calls EC2 to create and attach volumes, and pods cannot reach the node role
  # (IMDS hop limit 1), so it only works with a role of its own.
  cluster_addons = {
    coredns                         = {}
    kube-proxy                      = {}
    vpc-cni                         = { before_compute = true }
    aws-ebs-csi-driver              = { irsa_role_key = "ebs-csi" }
    metrics-server                  = {}
    amazon-cloudwatch-observability = { irsa_role_key = "cloudwatch" }
  }

  irsa_roles = {
    ebs-csi = {
      description                = "EBS CSI driver in ${local.eks_cluster_name}"
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
      managed_policy_arns        = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
    }
    cloudwatch = {
      description                = "CloudWatch agent and Fluent Bit in ${local.eks_cluster_name}"
      namespace_service_accounts = ["amazon-cloudwatch:cloudwatch-agent"]
      managed_policy_arns        = ["arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"]
    }
  }

  create_kms_key             = false
  kms_key_arn                = local.base.kms.eks
  cluster_log_kms_key_arn    = local.base.kms.logs
  cluster_log_retention_days = local.env.log_retention_days

  tags = local.common_tags
}

