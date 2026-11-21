mock_provider "google" {
  mock_data "google_compute_subnetwork" {
    defaults = {
      secondary_ip_range = [
        { range_name = "test-pods", ip_cidr_range = "10.21.0.0/16", reserved_internal_range = "" },
        { range_name = "test-services", ip_cidr_range = "10.22.0.0/20", reserved_internal_range = "" },
      ]
    }
  }

  mock_data "google_compute_address" {
    defaults = { address = "203.0.113.20" }
  }
}

variables {
  name       = "test"
  region     = "us-central1"
  project_id = "poc-test-project"
}

# These names must match modules/network/gcp; its tests pin the same ones.
run "uses_the_network_module_naming_convention" {
  command = plan

  assert {
    condition = (
      data.google_compute_network.this.name == "test" &&
      data.google_compute_subnetwork.nodes.name == "test-nodes" &&
      data.google_compute_address.nat.name == "test-nat"
    )
    error_message = "Lookups must use the names modules/network/gcp creates."
  }

  assert {
    condition     = output.pods_range_name == "test-pods" && output.services_range_name == "test-services"
    error_message = "Secondary range names must match modules/network/gcp."
  }

  assert {
    condition     = output.nat_egress_ips == tolist(["203.0.113.20"])
    error_message = "nat_egress_ips must be the reserved NAT address."
  }
}

run "fails_when_secondary_ranges_are_missing" {
  command = plan

  override_data {
    target = data.google_compute_subnetwork.nodes
    values = {
      secondary_ip_range = [
        { range_name = "test-pods", ip_cidr_range = "10.21.0.0/16", reserved_internal_range = "" },
      ]
    }
  }

  expect_failures = [data.google_compute_subnetwork.nodes]
}
