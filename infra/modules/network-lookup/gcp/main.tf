# Finds the network built by modules/network/gcp, using that module's naming
# convention: <name>, <name>-nodes, <name>-nat, <name>-pods, <name>-services.
# Both modules' tests pin the convention, so renaming on one side breaks a test.

locals {
  subnet_name         = "${var.name}-nodes"
  nat_address_name    = "${var.name}-nat"
  pods_range_name     = "${var.name}-pods"
  services_range_name = "${var.name}-services"
}

data "google_compute_network" "this" {
  project = var.project_id
  name    = var.name
}

data "google_compute_subnetwork" "nodes" {
  project = var.project_id
  region  = var.region
  name    = local.subnet_name

  lifecycle {
    postcondition {
      condition = alltrue([
        for r in [local.pods_range_name, local.services_range_name] :
        contains([for s in self.secondary_ip_range : s.range_name], r)
      ])
      error_message = "The node subnet is missing its pods or services secondary range. Has 10-network/gcp been applied?"
    }
  }
}

data "google_compute_address" "nat" {
  project = var.project_id
  region  = var.region
  name    = local.nat_address_name
}
