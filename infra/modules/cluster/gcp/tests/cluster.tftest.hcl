mock_provider "google" {
  mock_data "google_container_engine_versions" {
    defaults = { valid_master_versions = ["1.36.5-gke.1100000", "1.36.4-gke.1469000"] }
  }

  mock_resource "google_service_account" {
    defaults = { email = "test-gke-nodes@poc-test-project.iam.gserviceaccount.com" }
  }
}

variables {
  name                = "test"
  kubernetes_version  = "1.36"
  node_count          = 2
  machine_type        = "e2-standard-4"
  api_allowed_cidrs   = ["203.0.113.7/32"]
  labels              = { project = "test" }
  project_id          = "poc-test-project"
  zone                = "us-central1-a"
  network_id          = "projects/poc-test-project/global/networks/test"
  subnet_id           = "projects/poc-test-project/regions/us-central1/subnetworks/test-nodes"
  pods_range_name     = "test-pods"
  services_range_name = "test-services"
  secrets_kms_key_id  = "projects/poc-test-project/locations/us-central1/keyRings/test-gke/cryptoKeys/test-gke-secrets"
}

run "cilium_is_the_only_cni" {
  command = plan

  assert {
    condition     = google_container_cluster.this.datapath_provider == "LEGACY_DATAPATH"
    error_message = "Dataplane V2 must be off; Cilium is installed separately."
  }

  assert {
    condition = (
      !google_container_cluster.this.network_policy[0].enabled &&
      google_container_cluster.this.addons_config[0].network_policy_config[0].disabled
    )
    error_message = "GKE's network policy add-on must be off; Cilium enforces policy."
  }

  assert {
    condition = (
      one(google_container_node_pool.default.node_config[0].taint).key == "node.cilium.io/agent-not-ready" &&
      one(google_container_node_pool.default.node_config[0].taint).effect == "NO_EXECUTE"
    )
    error_message = "Nodes must carry the Cilium agent-not-ready NoExecute taint."
  }

  assert {
    condition     = google_container_cluster.this.initial_node_count == 0
    error_message = "No default node pool may be created: its nodes would lack the Cilium taint."
  }
}

run "cluster_is_hardened" {
  command = plan

  assert {
    condition     = google_container_cluster.this.private_cluster_config[0].enable_private_nodes
    error_message = "Nodes must have no external IPs."
  }

  assert {
    condition     = [for b in google_container_cluster.this.master_authorized_networks_config[0].cidr_blocks : b.cidr_block] == ["203.0.113.7/32"]
    error_message = "Only api_allowed_cidrs may reach the API."
  }

  assert {
    condition     = google_container_cluster.this.database_encryption[0].state == "ENCRYPTED"
    error_message = "Secrets must be encrypted with the customer-managed key."
  }

  assert {
    condition     = google_container_cluster.this.workload_identity_config[0].workload_pool == "poc-test-project.svc.id.goog"
    error_message = "Workload Identity must be on."
  }

  assert {
    condition     = google_container_node_pool.default.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA"
    error_message = "Pods must not see the node's credentials."
  }

  assert {
    condition     = google_container_node_pool.default.node_config[0].service_account == "test-gke-nodes@poc-test-project.iam.gserviceaccount.com"
    error_message = "Nodes must use the dedicated service account, not the Compute Engine default."
  }

  assert {
    condition     = google_project_iam_member.nodes.role == "roles/container.defaultNodeServiceAccount"
    error_message = "The node service account must only get the default node role."
  }
}

run "rejects_versions_too_old_for_a_poolless_cluster" {
  command = plan

  override_data {
    target = data.google_container_engine_versions.this
    values = { valid_master_versions = ["1.36.4-gke.1000000", "1.36.3-gke.9999999"] }
  }

  expect_failures = [data.google_container_engine_versions.this]
}

run "rejects_unavailable_minor_version" {
  command = plan

  override_data {
    target = data.google_container_engine_versions.this
    values = { valid_master_versions = [] }
  }

  expect_failures = [data.google_container_engine_versions.this]
}

run "rejects_api_open_to_internet" {
  command = plan

  variables {
    api_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.api_allowed_cidrs]
}
