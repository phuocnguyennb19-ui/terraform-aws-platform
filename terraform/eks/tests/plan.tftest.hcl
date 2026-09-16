mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333", arn = "arn:aws:sts::111122223333:assumed-role/ci/s" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"], zone_ids = ["apse1-az1", "apse1-az2", "apse1-az3"] }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::111122223333:role/ci" }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::114774131450:root" }
  }
}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "cloudinit" {}

run "eks_stack_for_a_mixed_environment" {
  command = plan
  variables {
    environment       = "dev"
    config_path       = "tests/fixtures/mixed_dev.yaml"
    base_state_bucket = "platform-state-dev"
    base_state_region = "ap-southeast-1"
  }
  override_data {
    target = data.terraform_remote_state.base
    values = {
      outputs = {
        vpc_id             = "vpc-0123456789abcdef0"
        private_subnet_ids = ["subnet-0aa", "subnet-0bb", "subnet-0cc"]
        public_subnet_ids  = ["subnet-0dd", "subnet-0ee", "subnet-0ff"]
        kms = {
          ebs     = "arn:aws:kms:ap-southeast-1:111122223333:key/11111111-1111-1111-1111-111111111111"
          rds     = "arn:aws:kms:ap-southeast-1:111122223333:key/22222222-2222-2222-2222-222222222222"
          logs    = "arn:aws:kms:ap-southeast-1:111122223333:key/33333333-3333-3333-3333-333333333333"
          secrets = "arn:aws:kms:ap-southeast-1:111122223333:key/44444444-4444-4444-4444-444444444444"
          eks     = "arn:aws:kms:ap-southeast-1:111122223333:key/55555555-5555-5555-5555-555555555555"
          ecr     = "arn:aws:kms:ap-southeast-1:111122223333:key/66666666-6666-6666-6666-666666666666"
        }
        security_group_ids = {
          alb         = "sg-0aaa"
          ecs         = "sg-0bbb"
          eks_cluster = "sg-0ccc"
          eks_node    = "sg-0ddd"
          rds         = "sg-0eee"
          elasticache = "sg-0fff"
        }
        sns_topic_arn  = "arn:aws:sns:ap-southeast-1:111122223333:platform-dev-alarms"
        connection_env = { DATABASE_HOST = "db.internal", DATABASE_PORT = "5432", DATABASE_NAME = "appdb" }
      }
    }
  }

  assert {
    condition     = length(module.eks) == 1 && keys(local.release_specs) == ["worker"]
    error_message = "the eks stack builds the cluster and the releases placed on eks"
  }
}
