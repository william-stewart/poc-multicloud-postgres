# Contract: infra/modules/network/contract.json
#
# Every implementation must return:
#   network_id          non-empty string
#   network_name        the `name` input
#   private_subnet_ids  list (not tuple) of non-empty strings, at least one
#   nat_egress_ips      list (not tuple) of IPv4 addresses, at least one
#
# A value `v` is a list, not a tuple, exactly when tolist(v) == v: lists and
# tuples never compare equal. Callers rely on this so that both clouds' outputs
# can be used interchangeably (for example in the same conditional expression).

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
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

  mock_resource "aws_eip" {
    defaults = { public_ip = "203.0.113.10" }
  }
}

mock_provider "google" {
  mock_resource "google_compute_address" {
    defaults = { address = "203.0.113.20" }
  }
}

run "aws" {
  # apply (against mocks) so computed outputs have values to check.
  command = apply

  module {
    source = "../../modules/network/aws"
  }

  variables {
    name     = "contract"
    region   = "us-east-1"
    cidr     = "10.10.0.0/16"
    labels   = { project = "contract" }
    zone_ids = ["use1-az1", "use1-az2", "use1-az4"]
  }

  assert {
    condition     = can(tostring(output.network_id)) && tostring(output.network_id) == output.network_id && length(output.network_id) > 0
    error_message = "network_id must be a non-empty string."
  }

  assert {
    condition     = output.network_name == "contract"
    error_message = "network_name must equal the name input."
  }

  assert {
    condition = (
      tolist(output.private_subnet_ids) == output.private_subnet_ids &&
      length(output.private_subnet_ids) > 0 &&
      alltrue([for s in output.private_subnet_ids : tostring(s) == s && length(s) > 0])
    )
    error_message = "private_subnet_ids must be a non-empty list of non-empty strings."
  }

  assert {
    condition = (
      tolist(output.nat_egress_ips) == output.nat_egress_ips &&
      length(output.nat_egress_ips) > 0 &&
      alltrue([for ip in output.nat_egress_ips : can(cidrhost("${ip}/32", 0))])
    )
    error_message = "nat_egress_ips must be a non-empty list of IPv4 addresses."
  }
}

run "gcp" {
  command = apply

  module {
    source = "../../modules/network/gcp"
  }

  variables {
    name          = "contract"
    region        = "us-central1"
    cidr          = "10.20.0.0/20"
    labels        = { project = "contract" }
    project_id    = "poc-contract-test"
    pods_cidr     = "10.21.0.0/16"
    services_cidr = "10.22.0.0/20"
  }

  assert {
    condition     = can(tostring(output.network_id)) && tostring(output.network_id) == output.network_id && length(output.network_id) > 0
    error_message = "network_id must be a non-empty string."
  }

  assert {
    condition     = output.network_name == "contract"
    error_message = "network_name must equal the name input."
  }

  assert {
    condition = (
      tolist(output.private_subnet_ids) == output.private_subnet_ids &&
      length(output.private_subnet_ids) > 0 &&
      alltrue([for s in output.private_subnet_ids : tostring(s) == s && length(s) > 0])
    )
    error_message = "private_subnet_ids must be a non-empty list of non-empty strings."
  }

  assert {
    condition = (
      tolist(output.nat_egress_ips) == output.nat_egress_ips &&
      length(output.nat_egress_ips) > 0 &&
      alltrue([for ip in output.nat_egress_ips : can(cidrhost("${ip}/32", 0))])
    )
    error_message = "nat_egress_ips must be a non-empty list of IPv4 addresses."
  }
}
