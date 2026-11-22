mock_provider "google" {}

variables {
  name          = "test"
  region        = "us-central1"
  project_id    = "poc-test-project"
  cidr          = "10.20.0.0/20"
  pods_cidr     = "10.21.0.0/16"
  services_cidr = "10.22.0.0/20"
  labels        = { project = "test" }
}

run "custom_mode_network" {
  command = plan

  assert {
    condition     = !google_compute_network.this.auto_create_subnetworks
    error_message = "The network must be custom mode; auto mode creates subnets in every region."
  }

  assert {
    condition     = google_compute_subnetwork.nodes.private_ip_google_access
    error_message = "Private nodes need Private Google Access."
  }

  assert {
    condition = (
      google_compute_subnetwork.nodes.secondary_ip_range[0].ip_cidr_range == "10.21.0.0/16" &&
      google_compute_subnetwork.nodes.secondary_ip_range[1].ip_cidr_range == "10.22.0.0/20"
    )
    error_message = "Pods and services must use the secondary ranges passed in, in that order."
  }

  assert {
    condition     = google_compute_subnetwork.nodes.log_config[0].metadata == "INCLUDE_ALL_METADATA"
    error_message = "Subnet flow logs must be on."
  }
}

# modules/network-lookup/gcp finds these resources by name; its tests pin the
# same convention, so renaming here must be matched there.
run "naming_convention_for_lookups" {
  command = plan

  assert {
    condition = (
      google_compute_network.this.name == "test" &&
      google_compute_subnetwork.nodes.name == "test-nodes" &&
      google_compute_address.nat.name == "test-nat" &&
      google_compute_subnetwork.nodes.secondary_ip_range[0].range_name == "test-pods" &&
      google_compute_subnetwork.nodes.secondary_ip_range[1].range_name == "test-services"
    )
    error_message = "Resource names changed; update modules/network-lookup/gcp to match."
  }
}

run "ingress_denied_by_default" {
  command = plan

  assert {
    condition = (
      google_compute_firewall.deny_all_ingress.direction == "INGRESS" &&
      google_compute_firewall.deny_all_ingress.priority == 65534 &&
      one(google_compute_firewall.deny_all_ingress.deny).protocol == "all" &&
      length(google_compute_firewall.deny_all_ingress.allow) == 0
    )
    error_message = "A lowest-priority, logged deny-all ingress rule must exist."
  }

  assert {
    condition     = google_compute_firewall.deny_all_ingress.source_ranges == toset(["0.0.0.0/0"]) && length(google_compute_firewall.deny_all_ingress.log_config) == 1
    error_message = "The deny rule must cover every source and be logged."
  }
}

run "nat_uses_reserved_ip_for_node_subnet_only" {
  command = plan

  assert {
    condition     = google_compute_router_nat.this.nat_ip_allocate_option == "MANUAL_ONLY"
    error_message = "Cloud NAT must use the reserved IP, so its egress address is known in advance."
  }

  assert {
    condition     = google_compute_router_nat.this.source_subnetwork_ip_ranges_to_nat == "LIST_OF_SUBNETWORKS"
    error_message = "Only listed subnets may use the NAT."
  }

  assert {
    condition     = google_compute_router_nat.this.log_config[0].enable
    error_message = "NAT error logging must be on."
  }
}

run "nat_translates_the_node_subnet_through_the_reserved_ip" {
  # apply (against mocks) so IDs and self links are known and can be compared.
  command = apply

  override_resource {
    target = google_compute_address.nat
    values = { self_link = "https://www.googleapis.com/compute/v1/projects/poc-test-project/regions/us-central1/addresses/test-nat", address = "203.0.113.20" }
  }

  override_resource {
    target = google_compute_subnetwork.nodes
    values = { id = "projects/poc-test-project/regions/us-central1/subnetworks/test-nodes" }
  }

  assert {
    condition     = google_compute_router_nat.this.nat_ips == toset(["https://www.googleapis.com/compute/v1/projects/poc-test-project/regions/us-central1/addresses/test-nat"])
    error_message = "Cloud NAT must use only the reserved address."
  }

  assert {
    condition = (
      length(google_compute_router_nat.this.subnetwork) == 1 &&
      one(google_compute_router_nat.this.subnetwork).name == "projects/poc-test-project/regions/us-central1/subnetworks/test-nodes" &&
      one(google_compute_router_nat.this.subnetwork).source_ip_ranges_to_nat == toset(["ALL_IP_RANGES"])
    )
    error_message = "Cloud NAT must translate the node subnet, including its pod range (ALL_IP_RANGES), and nothing else."
  }

  assert {
    condition     = google_compute_address.nat.address_type == "EXTERNAL" && output.nat_egress_ips == tolist(["203.0.113.20"])
    error_message = "nat_egress_ips must be the reserved external address; 30-data/aws limits the S3 reader to it."
  }
}

run "rejects_zero_sampling" {
  command = plan

  variables {
    flow_log_sampling = 0
  }

  expect_failures = [var.flow_log_sampling]
}
