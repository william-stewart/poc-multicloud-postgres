# Plain resources instead of terraform-google-modules/network: the network is
# six resources, and the community module would add the google-beta provider.

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = var.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# GCP already denies ingress implicitly; this makes the rule explicit and
# logged. GKE's own allow rules use priority 1000 and take precedence.
# AVD-GCP-0074 (large port range) is meant for allow rules; on a deny rule,
# covering every port is the point.
# trivy:ignore:AVD-GCP-0074
resource "google_compute_firewall" "deny_all_ingress" {
  project   = var.project_id
  name      = "${var.name}-deny-all-ingress"
  network   = google_compute_network.this.id
  direction = "INGRESS"
  priority  = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "nodes" {
  project       = var.project_id
  name          = "${var.name}-nodes"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.cidr
  stack_type    = "IPV4_ONLY"

  # Nodes have no external IPs; this lets them reach Google APIs anyway.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${var.name}-pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "${var.name}-services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = var.flow_log_sampling
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# A reserved egress IP, unlike Cloud NAT's auto-allocated ones, is known in
# advance, so access to the WAL bucket can later be limited to it.
resource "google_compute_address" "nat" {
  project      = var.project_id
  name         = "${var.name}-nat"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  labels       = var.labels
}

resource "google_compute_router" "this" {
  project = var.project_id
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

# Outbound only: private nodes and pods reach S3 over HTTPS through this NAT.
# Nothing can connect in through it.
resource "google_compute_router_nat" "this" {
  project = var.project_id
  name    = "${var.name}-nat"
  region  = var.region
  router  = google_compute_router.this.name

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = [google_compute_address.nat.self_link]

  # Only the node subnet, including its pod range, is translated.
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.nodes.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
