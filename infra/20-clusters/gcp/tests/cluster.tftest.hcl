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

# Values later stacks and scripts depend on.
run "outputs_match_what_downstream_expects" {
  command = plan

  assert {
    condition     = output.oidc_issuer_url == "https://container.googleapis.com/v1/projects/poc-test-project/locations/us-central1-a/clusters/poc-mcpg"
    error_message = "oidc_issuer_url must be GKE's issuer for this cluster."
  }

  # Same pattern as 30-data/aws's gke_oidc_issuer_url validation.
  assert {
    condition     = can(regex("^https://container\\.googleapis\\.com/v1/projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/locations/[a-z0-9-]+/clusters/[a-z0-9-]+$", output.oidc_issuer_url))
    error_message = "oidc_issuer_url must be accepted by 30-data/aws's gke_oidc_issuer_url validation."
  }

  assert {
    condition     = output.pods_cidr == "10.21.0.0/16" && output.workload_identity_pool == "poc-test-project.svc.id.goog"
    error_message = "k8s/ needs the pod range (Cilium native routing) and the Workload Identity pool."
  }

  assert {
    condition     = google_kms_crypto_key_iam_member.gke_secrets.crypto_key_id == "projects/poc-test-project/locations/us-central1/keyRings/poc-mcpg-gke/cryptoKeys/poc-mcpg-gke-secrets"
    error_message = "The GKE service agent must be granted the key from 00-bootstrap/gcp."
  }
}

run "requires_an_api_allowlist" {
  command = plan

  variables {
    api_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.api_allowed_cidrs]
}
