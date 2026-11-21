# Contract: infra/modules/network-lookup/contract.json
#
# Lookups return the same shared outputs as the network modules, with the same
# shapes (see network.tftest.hcl), so a downstream stack can't tell whether its
# network inputs came from a module or a lookup.

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }

  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"] }
  }

  mock_data "aws_nat_gateways" {
    defaults = { ids = ["nat-0123456789abcdef0"] }
  }

  mock_data "aws_nat_gateway" {
    defaults = { public_ip = "203.0.113.10" }
  }
}

mock_provider "google" {
  mock_data "google_compute_network" {
    defaults = { id = "projects/poc-contract-test/global/networks/contract" }
  }

  mock_data "google_compute_subnetwork" {
    defaults = {
      id = "projects/poc-contract-test/regions/us-central1/subnetworks/contract-nodes"
      secondary_ip_range = [
        { range_name = "contract-pods", ip_cidr_range = "10.21.0.0/16", reserved_internal_range = "" },
        { range_name = "contract-services", ip_cidr_range = "10.22.0.0/20", reserved_internal_range = "" },
      ]
    }
  }

  mock_data "google_compute_address" {
    defaults = { address = "203.0.113.20" }
  }
}

run "aws" {
  command = plan

  module {
    source = "../../modules/network-lookup/aws"
  }

  variables {
    name   = "contract"
    region = "us-east-1"
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
  command = plan

  module {
    source = "../../modules/network-lookup/gcp"
  }

  variables {
    name       = "contract"
    region     = "us-central1"
    project_id = "poc-contract-test"
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
