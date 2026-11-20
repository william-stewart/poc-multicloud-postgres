output "state_bucket" {
  description = "Name of the GCS bucket that holds OpenTofu state for the GCP stacks."
  value       = google_storage_bucket.state.name
}

output "state_kms_key_id" {
  description = "ID of the Cloud KMS key that encrypts the state bucket."
  value       = google_kms_crypto_key.state.id
}

output "backend_config" {
  description = "Values for `tofu init -backend-config=...` in the GCP stacks (add a per-stack prefix)."
  value = {
    bucket = google_storage_bucket.state.name
  }
}
