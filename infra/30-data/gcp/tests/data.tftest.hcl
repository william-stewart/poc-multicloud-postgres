mock_provider "google" {
  override_data {
    target = data.google_storage_project_service_account.gcs
    values = { email_address = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com" }
  }

  override_data {
    target = data.google_kms_crypto_key.wal
    values = { id = "projects/poc-test-project/locations/us-central1/keyRings/poc-mcpg-wal/cryptoKeys/poc-mcpg-wal" }
  }

  mock_resource "google_service_account" {
    defaults = {
      name   = "projects/poc-test-project/serviceAccounts/poc-mcpg-wal-writer@poc-test-project.iam.gserviceaccount.com"
      email  = "poc-mcpg-wal-writer@poc-test-project.iam.gserviceaccount.com"
      member = "serviceAccount:poc-mcpg-wal-writer@poc-test-project.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id = "poc-test-project"
}

run "bucket_is_private_and_encrypted" {
  command = plan

  assert {
    condition     = google_storage_bucket.wal.public_access_prevention == "enforced" && google_storage_bucket.wal.uniform_bucket_level_access
    error_message = "The WAL bucket must block public access and use uniform bucket-level access."
  }

  assert {
    condition     = google_storage_bucket.wal.encryption[0].default_kms_key_name == "projects/poc-test-project/locations/us-central1/keyRings/poc-mcpg-wal/cryptoKeys/poc-mcpg-wal"
    error_message = "The WAL bucket must use the customer-managed key from 00-bootstrap/gcp."
  }

  assert {
    condition     = google_storage_bucket.wal.versioning[0].enabled
    error_message = "Versioning must be on, so a bad delete can be recovered."
  }

  assert {
    condition     = google_storage_bucket.wal.location == "US-CENTRAL1"
    error_message = "The WAL bucket must sit in the GKE cluster's region."
  }

  assert {
    condition     = google_kms_crypto_key_iam_member.gcs_uses_wal_key.member == "serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
    error_message = "Only the Cloud Storage service agent should be granted the WAL key."
  }
}

run "writer_is_only_the_replica_cluster" {
  command = plan

  assert {
    condition     = google_service_account_iam_member.writer_workload_identity.member == "serviceAccount:poc-test-project.svc.id.goog[cnpg-db/pg-replica]"
    error_message = "Only the pg-replica service account in cnpg-db may act as the writer."
  }

  assert {
    condition     = google_service_account_iam_member.writer_workload_identity.role == "roles/iam.workloadIdentityUser"
    error_message = "The replica must reach the writer through Workload Identity, not a key."
  }

  assert {
    condition     = toset([for m in google_storage_bucket_iam_member.writer : m.role]) == toset(["roles/storage.objectUser", "roles/storage.legacyBucketReader"])
    error_message = "The writer may only use objects in the WAL bucket and read the bucket's metadata."
  }

  assert {
    condition     = alltrue([for m in google_storage_bucket_iam_member.writer : m.bucket == "poc-test-project-poc-mcpg-wal"])
    error_message = "The writer's grants must be on the WAL bucket only."
  }
}

run "rejects_invalid_project_id" {
  command = plan

  variables {
    project_id = "Not_A_Project"
  }

  expect_failures = [var.project_id]
}
