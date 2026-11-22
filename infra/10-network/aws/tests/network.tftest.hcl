mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az1", "use1-az2", "use1-az4"]
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }

  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-log/mock" }
  }
}

run "uses_shared_settings" {
  command = plan

  assert {
    condition     = module.network.azs == ["us-east-1a", "us-east-1b", "us-east-1c"]
    error_message = "The VPC must span the three AZs from settings, in their order."
  }

  # Later stacks (network-lookup/aws) find the VPC by this name.
  assert {
    condition     = module.network.network_name == "poc-mcpg"
    error_message = "The VPC must be named after the settings prefix."
  }
}
