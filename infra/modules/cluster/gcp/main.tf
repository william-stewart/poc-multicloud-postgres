locals {
  # Creating a cluster with no node pool (initial_node_count = 0) needs this
  # GKE version or later. Versions look like 1.36.5-gke.1234000.
  min_poolless_version = { minor = 36, patch = 4, gke = 1469000 }

  # Nodes start tainted so no pod schedules until the Cilium agent is ready
  # on them; Cilium removes the taint itself.
  cilium_taint = {
    key    = "node.cilium.io/agent-not-ready"
    value  = "true"
    effect = "NO_EXECUTE"
  }
}

# Fail at plan time, with a clear message, if GKE doesn't offer the requested
# minor version in this zone. Read only for its postconditions.
# tflint-ignore: terraform_unused_declarations
data "google_container_engine_versions" "this" {
  project        = var.project_id
  location       = var.zone
  version_prefix = "${var.kubernetes_version}."

  lifecycle {
    postcondition {
      condition     = length(self.valid_master_versions) > 0
      error_message = "GKE offers no ${var.kubernetes_version}.x version in ${var.zone}. Pick another version in the settings module."
    }

    postcondition {
      condition = anytrue([
        for v in self.valid_master_versions : (
          tonumber(split(".", v)[1]) > local.min_poolless_version.minor ||
          (tonumber(split(".", v)[1]) == local.min_poolless_version.minor && (
            tonumber(split(".", split("-", v)[0])[2]) > local.min_poolless_version.patch ||
            (tonumber(split(".", split("-", v)[0])[2]) == local.min_poolless_version.patch &&
            tonumber(split(".", v)[3]) >= local.min_poolless_version.gke)
          ))
        )
      ])
      error_message = "Creating the cluster without a default node pool needs GKE 1.36.4-gke.1469000 or later, and none is offered in ${var.zone}."
    }
  }
}

# Dedicated node identity with only the role Google recommends for nodes,
# instead of the Compute Engine default service account (project Editor).
resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "${var.name}-gke-nodes"
  display_name = "GKE nodes for ${var.name}"
}

resource "google_project_iam_member" "nodes" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# Accepted: GKE network policy is deliberately off, because Cilium enforces
# NetworkPolicy and CiliumNetworkPolicy (see the checkov skip below).
# trivy:ignore:AVD-GCP-0056
resource "google_container_cluster" "this" {
  #checkov:skip=CKV_GCP_69:False positive. There is no default node pool (initial_node_count = 0); the only pool sets GKE_METADATA (tests/cluster.tftest.hcl).
  #checkov:skip=CKV_GCP_12:GKE network policy is deliberately off: Cilium enforces NetworkPolicy and CiliumNetworkPolicy.
  #checkov:skip=CKV_GCP_61:Intranode visibility is a GKE dataplane feature; flows are observed with Cilium Hubble instead.
  #checkov:skip=CKV_GCP_65:RBAC is managed with IAM and Kubernetes RBAC for a single operator; Google Groups for RBAC is out of scope.
  #checkov:skip=CKV_GCP_66:Binary Authorization is out of scope for the PoC; images come from pinned Helm chart versions.
  project  = var.project_id
  name     = var.name
  location = var.zone

  # Torn down nightly.
  deletion_protection = false

  # Initial version; the release channel keeps it patched afterwards. GKE
  # accepts a minor version ("1.36") and picks its newest patch.
  min_master_version = var.kubernetes_version
  release_channel {
    channel = var.release_channel
  }

  network         = var.network_id
  subnetwork      = var.subnet_id
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Cilium is the only CNI: the legacy datapath (not Dataplane V2, which is
  # Google's own Cilium) and no GKE network policy add-on.
  datapath_provider = "LEGACY_DATAPATH"
  network_policy {
    enabled = false
  }

  addons_config {
    network_policy_config {
      disabled = true
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # Nodes have no external IPs; the API endpoint is public but limited to
  # api_allowed_cidrs.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.api_allowed_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = "operator-${cidr_blocks.key}"
      }
    }
  }

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  database_encryption {
    state    = "ENCRYPTED"
    key_name = var.secrets_kms_key_id
  }

  enable_shielded_nodes = true
  enable_legacy_abac    = false

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  resource_labels = var.labels

  # No default node pool: only the tainted pool below ever exists, so no node
  # runs without the Cilium taint. The version data source above checks that
  # GKE offers a version new enough for this.
  initial_node_count = 0

  depends_on = [google_project_iam_member.nodes]
}

resource "google_container_node_pool" "default" {
  project  = var.project_id
  name     = "${var.name}-default"
  cluster  = google_container_cluster.this.id
  location = var.zone

  node_count = var.node_count

  # The pool follows the control plane version through the release channel.
  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.machine_type
    image_type   = var.node_image
    disk_type    = "pd-balanced"
    disk_size_gb = 50

    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    resource_labels = var.labels

    taint {
      key    = local.cilium_taint.key
      value  = local.cilium_taint.value
      effect = local.cilium_taint.effect
    }

    # Pods see the GKE metadata server, not the node's credentials.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}
