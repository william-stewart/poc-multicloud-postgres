mock_provider "aws" {
  # Mocks return random strings, but IAM policies must be valid JSON.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # Mocks return random strings, but these attributes are validated as ARNs.
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

  override_data {
    target = data.aws_availability_zones.available
    # Sorted by name, as AWS returns them; the account maps IDs to names freely.
    values = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az4", "use1-az1", "use1-az2"]
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }
}

variables {
  name     = "test"
  region   = "us-east-1"
  cidr     = "10.10.0.0/16"
  labels   = { project = "test" }
  zone_ids = ["use1-az1", "use1-az2", "use1-az4"]
}

run "subnet_layout" {
  command = plan

  assert {
    condition     = local.azs == ["us-east-1b", "us-east-1c", "us-east-1a"]
    error_message = "AZ names must follow the order of zone_ids."
  }

  assert {
    condition     = local.private_subnets == ["10.10.0.0/19", "10.10.32.0/19", "10.10.64.0/19"]
    error_message = "Private subnets must be one /19 per AZ, from the start of the VPC range."
  }

  assert {
    condition     = local.public_subnets == ["10.10.96.0/24", "10.10.97.0/24", "10.10.98.0/24"]
    error_message = "Public subnets must be one /24 per AZ, after the private ranges."
  }

  assert {
    condition = alltrue([
      for p in local.public_subnets : !anytrue([for q in local.private_subnets : cidrcontains(q, cidrhost(p, 0))])
    ])
    error_message = "Public and private subnets must not overlap."
  }
}

run "subnets_tagged_for_lookup" {
  command = plan

  assert {
    condition     = local.private_subnet_tags.tier == "private" && local.public_subnet_tags.tier == "public"
    error_message = "Subnets must carry the tier tag that network-lookup/aws filters on."
  }
}

run "default_security_group_denies_all" {
  command = plan

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "The default security group must have no rules."
  }
}

run "s3_traffic_skips_nat" {
  command = plan

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway"
    error_message = "S3 must be reached through a gateway endpoint."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-1.s3"
    error_message = "The S3 endpoint must be in the VPC's region."
  }
}

run "flow_logs_encrypted" {
  command = plan

  assert {
    condition     = aws_kms_key.flow_logs.enable_key_rotation
    error_message = "The flow log key must rotate."
  }

  assert {
    condition     = strcontains(aws_kms_key.flow_logs.policy, "log-group:/aws/vpc-flow-log/*")
    error_message = "CloudWatch Logs may use the key only for VPC flow log groups."
  }
}

run "rejects_single_az" {
  command = plan

  variables {
    zone_ids = ["use1-az1"]
  }

  expect_failures = [var.zone_ids]
}

run "rejects_duplicate_zones" {
  command = plan

  variables {
    zone_ids = ["use1-az1", "use1-az1"]
  }

  expect_failures = [var.zone_ids]
}
