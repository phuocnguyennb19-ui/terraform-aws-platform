# The developer contract: config.yaml → validated, policy-checked, deterministic Helm values.
# Every run targets terraform_data.config, whose preconditions depend on the whole mapping, so no
# AWS resource or Helm release is planned and no credentials are needed.

mock_provider "aws" {}
mock_provider "helm" {}

variables {
  environment = "dev"
  config_path = "tests/fixtures/valid_dev.yaml"
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
    condition     = local.release_specs["api"].values.image.repository == "111122223333.dkr.ecr.ap-southeast-1.amazonaws.com/eks/api" && local.release_specs["api"].values.image.tag == "1.4.2"
    error_message = "A short image name must resolve to this account's ECR under the eks/ prefix, split into repository and tag."
  }

  assert {
    condition     = local.release_specs["api"].values.fullnameOverride == "api" && local.release_specs["worker"].internal_url == "http://worker:8080"
    error_message = "Every service must be reachable in the cluster at http://<name>:8080."
  }

  assert {
    condition     = local.release_specs["api"].values.probes.readiness.httpGet.path == "/healthz" && local.release_specs["api"].values.service.targetPort == 8080
    error_message = "Readiness must follow health_check on port 8080."
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
    condition     = local.chart.ecr_registry_id == "111122223333" && local.chart.version == "2.0.0"
    error_message = "An ECR chart registry must be recognised for authentication, at the pinned version."
  }

  assert {
    condition     = local.access_entries["gitlab-plan"].policy_associations["admin-view"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
    error_message = "cluster.access must map to an EKS access policy."
  }

  assert {
    condition     = local.enabled.database && !local.enabled.cache && local.enabled.ecr
    error_message = "Only what the config asks for is enabled."
  }

  assert {
    condition     = toset(local.ecr_repositories) == toset(["api", "worker"])
    error_message = "One ECR repository per image name."
  }
}

run "prod_policy_defaults" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    environment = "prod"
    config_path = "tests/fixtures/valid_prod.yaml"
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
    config_path = "tests/fixtures/prod_single_replica.yaml"
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
    config_path = "tests/fixtures/prod_edit_access.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_cluster_admin_access" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/cluster_admin_access.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_chart_version_range" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/chart_version_range.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_missing_chart" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/missing_chart.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_unknown_key" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/unknown_key.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_latest_tag" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/latest_tag.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_environment_mismatch" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    environment = "staging"
    config_path = "tests/fixtures/valid_dev.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_config_path_outside_fixtures" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "prod/config.yaml"
  }

  expect_failures = [var.config_path]
}
