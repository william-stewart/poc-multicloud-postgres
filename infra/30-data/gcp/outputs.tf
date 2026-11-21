output "wal_bucket" {
  description = "GCS bucket for the GKE cluster's WAL archive and base backups."
  value       = google_storage_bucket.wal.name
}

output "wal_writer_service_account" {
  description = "Google service account that cnpg-db/pg-replica uses through Workload Identity."
  value       = google_service_account.writer.email
}
