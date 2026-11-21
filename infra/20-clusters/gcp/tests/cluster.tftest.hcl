mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }

  mock_data "google_kms_key_ring" {
    defaults = { id = "projects/poc-test-project/locations/us-central1/keyRings/poc-mcpg-gke" }
  }

  mock_data "google_kms_crypto_key" {
    defaults = { id = "projects/poc-test-project/locations/us-central1/keyRings/poc-mcpg-gke/cryptoKeys/poc-mcpg-gke-secrets" }
  }

  mock_data "google_container_engine_versions" {
    defaults = { valid_master_versions = ["1.36.5-gke.1100000"] }
  }

  # network-lookup/gcp
  mock_data "google_compute_subnetwork" {
    defaults = {
      id = "projects/poc-test-project/regions/us-central1/subnetworks/poc-mcpg-nodes"
      secondary_ip_range = [
        { range_name = "poc-mcpg-pods", ip_cidr_range = "10.21.0.0/16", reserved_internal_range = "" },
        { range_name = "poc-mcpg-services", ip_cidr_range = "10.22.0.0/20", reserved_internal_range = "" },
      ]
    }
  }

  mock_data "google_compute_address" {
    defaults = { address = "203.0.113.20" }
  }

  mock_resource "google_service_account" {
    defaults = { email = "poc-mcpg-gke-nodes@poc-test-project.iam.gserviceaccount.com" }
  }
}

variables {
  project_id        = "poc-test-project"
  api_allowed_cidrs = ["203.0.113.7/32"]
}

run "wires_settings_network_and_key" {
  command = plan

  assert {
    condition     = google_kms_crypto_key_iam_member.gke_secrets.member == "serviceAccount:service-123456789012@container-engine-robot.iam.gserviceaccount.com"
    error_message = "Only the GKE service agent may use the Secrets key."
  }

  assert {
    condition     = data.google_kms_crypto_key.gke_secrets.name == "poc-mcpg-gke-secrets" && data.google_kms_key_ring.gke.name == "poc-mcpg-gke"
    error_message = "The key must be the one 00-bootstrap/gcp creates."
  }

  assert {
    condition     = module.network.pods_range_name == "poc-mcpg-pods"
    error_message = "The cluster must use the pod range found by network-lookup/gcp."
  }
}

run "requires_an_api_allowlist" {
  command = plan

  variables {
    api_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.api_allowed_cidrs]
}
