# The developer contract on platform eks: config.yaml → validated, policy-checked, deterministic Helm
# values. Every run targets terraform_data.config, so no AWS resource is planned, no Helm release is
# touched and no credentials are needed.

mock_provider "aws" {}

variables {
  environment = "dev"
  config_path = "tests/fixtures/eks_valid_dev.yaml"
}

run "dev_config_maps_to_helm_values" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  assert {
    condition     = local.release_specs["api"].values.resources.requests.cpu == "500m" && local.release_specs["api"].values.resources.requests.memory == "1Gi" && local.release_specs["api"].values.resources.limits.memory == "1Gi"
    error_message = "size: medium must become 500m CPU / 1Gi requests and a 1Gi memory limit."
  }

  assert {
    condition     = local.release_specs["api"].values.replicaCount == 2 && local.release_specs["worker"].values.replicaCount == 1
    error_message = "replicas must map to replicaCount; dev defaults to 1."
  }

  assert {
    condition     = local.release_specs["api"].values.image.repository == "111122223333.dkr.ecr.ap-southeast-1.amazonaws.com/api" && local.release_specs["api"].values.image.tag == "1.4.2"
    error_message = "A short image name must resolve to this account's ECR — the same repository ECS uses — split into repository and tag."
  }

  assert {
    condition     = local.release_specs["api"].values.fullnameOverride == "api" && local.release_specs["worker"].internal_url == "http://worker:8080"
    error_message = "Every service must be reachable in the cluster at http://<name>:8080."
  }

  assert {
    condition     = local.release_specs["api"].values.probes.readiness.httpGet.path == "/healthz" && local.release_specs["api"].values.service.port == 8080
    error_message = "Readiness must follow health_check, and the Service must listen on 8080."
  }

  assert {
    condition     = local.release_specs["worker"].values.autoscaling.enabled && local.release_specs["worker"].values.autoscaling.maxReplicas == 4 && !local.release_specs["api"].values.autoscaling.enabled
    error_message = "autoscaling must be on only where configured."
  }

  assert {
    condition     = local.release_specs["api"].values.podDisruptionBudget.enabled && !local.release_specs["worker"].values.podDisruptionBudget.enabled
    error_message = "A PodDisruptionBudget only where at least 2 pods run."
  }

  assert {
    condition     = local.release_specs["api"].values.env == { LOG_LEVEL = "info" }
    error_message = "env must reach the Helm values."
  }

  assert {
    condition     = local.release_specs["api"].values.service.targetPort == 8080 && local.release_specs["api"].values.podDisruptionBudget.maxUnavailable == 1 && local.release_specs["api"].values.extraVolumeMounts[0].mountPath == "/tmp"
    error_message = "The values must match the chart's contract: both Service ports 8080, exactly one PDB bound, and a writable /tmp under a read-only root filesystem."
  }

  assert {
    condition     = local.chart.ecr_registry_id == "999988887777" && local.chart.version == "2.0.0" && local.chart.registry_host == "999988887777.dkr.ecr.ap-southeast-1.amazonaws.com"
    error_message = "The pinned chart must be recognised as an ECR registry so the deploy job can authenticate to it."
  }

  assert {
    condition     = local.access_entries["developers"].policy_associations["view"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    error_message = "eks.access must map to an EKS access policy."
  }

  assert {
    condition     = local.enabled.eks && !local.enabled.ecs && !local.enabled.alb && length(local.service_specs) == 0
    error_message = "platform.type eks builds the cluster and no ECS service or ALB."
  }

  assert {
    condition     = local.enabled.database && !local.enabled.cache && toset(local.ecr_repositories) == toset(["api", "worker"])
    error_message = "Only what the config asks for is enabled; one ECR repository per image name."
  }
}

run "prod_policy_defaults" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    environment = "prod"
    config_path = "tests/fixtures/eks_valid_prod.yaml"
  }

  assert {
    condition     = local.release_specs["api"].values.replicaCount == 2 && local.release_specs["api"].values.podDisruptionBudget.enabled
    error_message = "prod must default to 2 replicas with a PodDisruptionBudget."
  }

  assert {
    condition     = !local.env.eks_public_api && local.env.rds_multi_az && !local.env.single_nat_gateway
    error_message = "prod policy: private EKS API, multi-AZ database, one NAT gateway per AZ."
  }
}

run "rejects_prod_single_replica" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    environment = "prod"
    config_path = "tests/fixtures/eks_prod_single_replica.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_prod_edit_access" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    environment = "prod"
    config_path = "tests/fixtures/eks_prod_edit_access.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_cluster_admin_access" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/eks_cluster_admin_access.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_public_service" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/eks_public_service.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_dns_on_eks" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/eks_with_dns.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_chart_version_range" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/eks_chart_version_range.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_missing_chart" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/eks_missing_chart.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_chart_on_ecs" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/ecs_with_chart.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "secrets_from_aws_secrets_manager" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/eks_secrets_aws.yaml"
  }

  assert {
    condition     = local.release_specs["api"].values.externalSecret.enabled && local.release_specs["api"].values.externalSecret.injectEnvFrom
    error_message = "A service with secrets must get an ExternalSecret, injected as environment variables."
  }

  assert {
    condition     = local.release_specs["api"].values.externalSecret.secretStoreRef == { name = "aws-secretsmanager", kind = "ClusterSecretStore" }
    error_message = "provider aws must default to the aws-secretsmanager ClusterSecretStore."
  }

  assert {
    condition     = local.release_specs["api"].values.externalSecret.data[0] == { secretKey = "API_KEY", remoteRef = { key = "platform/api", property = "api_key" } }
    error_message = "<key>#<property> must split into remoteRef.key and remoteRef.property."
  }

  assert {
    condition     = local.release_specs["api"].values.externalSecret.data[1] == { secretKey = "DB_PASSWORD", remoteRef = { key = "arn:aws:secretsmanager:ap-southeast-1:111122223333:secret:api-db-AbCdEf" } }
    error_message = "A reference without # must become a bare remoteRef.key — an ARN is a valid key on aws."
  }
}

run "secrets_from_vault" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/eks_secrets_vault.yaml"
  }

  assert {
    condition     = local.release_specs["api"].values.externalSecret.secretStoreRef.name == "vault-kv" && local.secret_store.provider == "vault"
    error_message = "provider vault must use the named store; nothing in this path touches AWS."
  }

  assert {
    condition     = local.release_specs["api"].values.externalSecret.data[0].remoteRef.key == "platform/api"
    error_message = "A vault reference is a KV path, mapped the same way as an aws one."
  }
}

run "no_secrets_means_no_external_secret" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  assert {
    condition     = !local.release_specs["api"].values.externalSecret.enabled && length(local.release_specs["api"].values.externalSecret.data) == 0
    error_message = "A service without secrets must not render an ExternalSecret."
  }
}

run "rejects_secrets_without_a_store" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/eks_secrets_without_store.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_an_aws_arn_on_vault" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/eks_secrets_arn_on_vault.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_unknown_secret_provider" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/eks_unknown_secret_provider.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_secret_store_on_ecs" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/ecs_with_secret_store.yaml"
  }

  expect_failures = [terraform_data.config]
}
