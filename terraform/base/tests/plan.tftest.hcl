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
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::114774131450:root" }
  }
}
mock_provider "random" {}

run "base_for_a_mixed_environment" {
  command = plan
  variables {
    environment = "dev"
    config_path = "tests/fixtures/mixed_dev.yaml"
  }
  assert {
    condition     = length(module.rds) == 1 && length(module.elasticache) == 0 && length(module.ecr) == 1
    error_message = "base builds the shared data layer once, for both runtimes"
  }
}
