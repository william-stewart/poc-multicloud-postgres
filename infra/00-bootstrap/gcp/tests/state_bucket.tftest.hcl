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

run "state_bucket_uses_the_state_key" {
  command = plan

  # plan, not apply: prevent_destroy would stop the test from cleaning up.
  # The overrides make the key IDs known at plan time; mocks would also give
  # every key the same random ID.
  override_resource {
    target = google_kms_crypto_key.state
    values = { id = "projects/poc-test-project/locations/us-central1/keyRings/poc-mcpg-tfstate/cryptoKeys/poc-mcpg-tfstate" }
  }

  override_resource {
    target = google_kms_crypto_key.gke_secrets
    values = { id = "projects/poc-test-project/locations/us-central1/keyRings/poc-mcpg-gke/cryptoKeys/poc-mcpg-gke-secrets" }
  }

  override_resource {
    target = google_kms_crypto_key.wal
    values = { id = "projects/poc-test-project/locations/us-central1/keyRings/poc-mcpg-wal/cryptoKeys/poc-mcpg-wal" }
  }

  assert {
    condition = (
      google_storage_bucket.state.encryption[0].default_kms_key_name == "projects/poc-test-project/locations/us-central1/keyRings/poc-mcpg-tfstate/cryptoKeys/poc-mcpg-tfstate" &&
      google_kms_crypto_key_iam_member.gcs_uses_state_key.crypto_key_id == google_storage_bucket.state.encryption[0].default_kms_key_name
    )
    error_message = "The state bucket must use the state key, and the Cloud Storage service agent must be granted that same key."
  }

  assert {
    condition     = output.backend_config.bucket == "poc-test-project-poc-mcpg-tfstate"
    error_message = "backend_config must name the state bucket (docs/deploy.md's gcp_init reads it)."
  }
}

# Later stacks read these APIs at plan time or rely on them at apply time.
run "enables_the_apis_later_stacks_need" {
  command = plan

  assert {
    condition = alltrue([
      for api in ["cloudkms.googleapis.com", "storage.googleapis.com", "iam.googleapis.com", "sts.googleapis.com", "container.googleapis.com"] :
      contains(keys(google_project_service.this), api)
    ])
    error_message = "KMS, Storage, IAM, STS and Kubernetes Engine must be enabled here: later stacks read them at plan time."
  }

  assert {
    condition     = alltrue([for s in google_project_service.this : !s.disable_on_destroy])
    error_message = "Destroying the bootstrap stack must not switch off APIs other stacks use."
  }
}

# GCP rejects these at apply time; mocks don't, so check them here.
run "names_fit_gcp_limits" {
  command = plan

  variables {
    project_id = "a23456789012345678901234567890"
  }

  assert {
    condition     = length(google_storage_bucket.state.name) <= 63
    error_message = "The state bucket name must be at most 63 characters, even for a 30-character project ID."
  }

  assert {
    condition     = can(regex("^[a-z0-9-]{4,32}$", google_iam_workload_identity_pool.eks.workload_identity_pool_id)) && length(google_iam_workload_identity_pool.eks.display_name) <= 32
    error_message = "The pool ID must be 4-32 characters of [a-z0-9-], and its display name at most 32 characters."
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
