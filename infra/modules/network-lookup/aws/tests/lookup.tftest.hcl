mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }

  mock_data "aws_nat_gateways" {
    defaults = { ids = ["nat-0123456789abcdef0"] }
  }

  mock_data "aws_nat_gateway" {
    defaults = { public_ip = "203.0.113.10" }
  }
}

variables {
  name   = "test"
  region = "us-east-1"
}

run "returns_sorted_shared_outputs" {
  command = plan

  override_data {
    target = data.aws_subnets.private
    values = { ids = ["subnet-c", "subnet-a", "subnet-b"] }
  }

  assert {
    condition     = output.private_subnet_ids == tolist(["subnet-a", "subnet-b", "subnet-c"])
    error_message = "Subnet IDs must be sorted so downstream plans stay stable."
  }

  assert {
    condition     = output.nat_egress_ips == tolist(["203.0.113.10"])
    error_message = "NAT egress IPs must come from the VPC's NAT gateways."
  }

  assert {
    condition     = output.network_id == "vpc-0123456789abcdef0"
    error_message = "network_id must be the looked-up VPC."
  }
}

run "filters_on_the_tags_the_network_module_sets" {
  command = plan

  override_data {
    target = data.aws_subnets.private
    values = { ids = ["subnet-a", "subnet-b"] }
  }

  assert {
    condition     = one([for f in data.aws_vpc.this.filter : f.values if f.name == "tag:Name"]) == toset(["test"])
    error_message = "The VPC must be found by its Name tag."
  }

  assert {
    condition     = one([for f in data.aws_subnets.private.filter : f.values if f.name == "tag:tier"]) == toset(["private"])
    error_message = "Private subnets must be found by tier = private."
  }
}

run "fails_when_too_few_private_subnets" {
  command = plan

  override_data {
    target = data.aws_subnets.private
    values = { ids = ["subnet-a"] }
  }

  expect_failures = [data.aws_subnets.private]
}
