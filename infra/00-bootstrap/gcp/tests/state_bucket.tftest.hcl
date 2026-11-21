mock_provider "google" {
  override_data {
    target = data.google_storage_project_service_account.gcs
    values = { email_address = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com" }
  }
}

variables {
  project_id = "poc-test-project"
}

run "state_bucket_is_private_and_encrypted" {
  command = plan

  assert {
    condition     = google_storage_bucket.state.public_access_prevention == "enforced"
    error_message = "Public access prevention must be enforced on the state bucket."
  }

  assert {
    condition     = google_storage_bucket.state.uniform_bucket_level_access
    error_message = "The state bucket must use uniform bucket-level access (no object ACLs)."
  }

  assert {
    condition     = google_storage_bucket.state.versioning[0].enabled
    error_message = "State versioning must be on so a bad apply can be rolled back."
  }

  assert {
    condition     = length(google_storage_bucket.state.encryption) == 1
    error_message = "The state bucket must use a customer-managed encryption key."
  }

  assert {
    condition     = google_kms_crypto_key.state.rotation_period == "7776000s"
    error_message = "The state key must rotate every 90 days."
  }

  assert {
    condition     = google_kms_crypto_key_iam_member.gcs_uses_state_key.member == "serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
    error_message = "Only the Cloud Storage service agent should be granted the state key."
  }
}

run "gke_secrets_key_is_long_lived" {
  command = plan

  assert {
    condition     = google_kms_crypto_key.gke_secrets.rotation_period == "7776000s" && google_kms_key_ring.gke.location == "us-central1"
    error_message = "The GKE secrets key must rotate every 90 days and sit in the cluster's region."
  }
}

run "wal_key_is_long_lived" {
  command = plan

  assert {
    condition     = google_kms_crypto_key.wal.rotation_period == "7776000s" && google_kms_key_ring.wal.location == "us-central1"
    error_message = "The WAL archive key must rotate every 90 days and sit in the bucket's region."
  }
}

# These resources hold the state of every GCP stack and the GKE Secrets key;
# Cloud KMS names can never be reused. Their names must never change.
run "names_are_stable" {
  command = plan

  assert {
    condition = (
      google_storage_bucket.state.name == "poc-test-project-poc-mcpg-tfstate" &&
      google_storage_bucket.state.location == "US-CENTRAL1" &&
      google_kms_key_ring.state.name == "poc-mcpg-tfstate" &&
      google_kms_crypto_key.state.name == "poc-mcpg-tfstate" &&
      google_kms_key_ring.gke.name == "poc-mcpg-gke" &&
      google_kms_crypto_key.gke_secrets.name == "poc-mcpg-gke-secrets" &&
      google_kms_key_ring.wal.name == "poc-mcpg-wal" &&
      google_kms_crypto_key.wal.name == "poc-mcpg-wal" &&
      google_iam_workload_identity_pool.eks.workload_identity_pool_id == "poc-mcpg-eks" &&
      google_kms_key_ring.state.location == "us-central1"
    )
    error_message = "A state bucket or KMS name or location changed; that would replace live resources."
  }
}

run "rejects_invalid_project_id" {
  command = plan

  variables {
    project_id = "Not_A_Project"
  }

  expect_failures = [var.project_id]
}
