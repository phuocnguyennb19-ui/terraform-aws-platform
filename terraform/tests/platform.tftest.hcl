# The developer contract: config.yaml → validated, policy-checked, deterministic module inputs.
# Every run targets terraform_data.config, whose preconditions depend on the whole mapping, so no
# AWS resource is planned and no credentials are needed.

mock_provider "aws" {}

variables {
  environment = "dev"
  config_path = "tests/fixtures/valid_dev.yaml"
}

run "dev_config_maps_to_module_inputs" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  assert {
    condition     = local.service_specs["api"].cpu == 512 && local.service_specs["api"].memory == 1024
    error_message = "size: medium must become 512 CPU units / 1024 MiB."
  }

  assert {
    condition     = local.service_specs["api"].desired_count == 2 && local.service_specs["worker"].desired_count == 1
    error_message = "replicas must map to desired_count; dev defaults to 1."
  }

  assert {
    condition     = local.service_specs["api"].image == "111122223333.dkr.ecr.ap-southeast-1.amazonaws.com/api:1.4.2"
    error_message = "A short image name must resolve to this account's ECR."
  }

  assert {
    condition     = local.service_specs["api"].public && !local.service_specs["worker"].public
    error_message = "public must default to false."
  }

  assert {
    condition     = local.service_specs["worker"].internal_url == "http://worker:8080"
    error_message = "Every service must be reachable privately at http://<name>:8080."
  }

  assert {
    condition     = local.service_specs["worker"].autoscaling.enabled && local.service_specs["worker"].autoscaling.max == 4 && !local.service_specs["api"].autoscaling.enabled
    error_message = "autoscaling must be on only where configured."
  }

  assert {
    condition     = length(local.service_specs["api"].task_exec_secret_arns) == 1 && local.service_specs["api"].task_exec_secret_arns[0] == "arn:aws:secretsmanager:ap-southeast-1:111122223333:secret:api-key-AbCdEf"
    error_message = "The execution role must be granted exactly the referenced secret, without its JSON-key suffix."
  }

  assert {
    condition     = local.service_specs["api"].enable_execute_command
    error_message = "ECS Exec is on outside prod."
  }

  assert {
    condition     = local.enabled.database && !local.enabled.cache && local.enabled.alb && local.enabled.ecr
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
    condition     = local.service_specs["api"].desired_count == 2
    error_message = "prod must default to 2 replicas."
  }

  assert {
    condition     = !local.service_specs["api"].enable_execute_command
    error_message = "ECS Exec must be off in prod."
  }

  assert {
    condition     = local.env.rds_multi_az && local.env.rds_backup_retention_days == 30 && !local.env.single_nat_gateway
    error_message = "prod policy: multi-AZ database, 30-day backups, one NAT gateway per AZ."
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

run "rejects_prod_public_without_https" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    environment = "prod"
    config_path = "tests/fixtures/prod_public_without_https.yaml"
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

run "rejects_invalid_size" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/invalid_size.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_invalid_replicas" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/invalid_replicas.yaml"
  }

  expect_failures = [terraform_data.config]
}

run "rejects_missing_account" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/missing_account.yaml"
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

run "rejects_secret_value_in_env" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/secret_in_env.yaml"
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

run "rejects_invalid_environment" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
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

run "rejects_unquoted_arn_as_invalid_yaml" {
  command = plan
  plan_options {
    target = [terraform_data.config]
  }

  variables {
    config_path = "tests/fixtures/unquoted_arn.yaml"
  }

  expect_failures = [terraform_data.config]
}
