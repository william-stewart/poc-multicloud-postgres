output "wal_bucket" {
  description = "GCS bucket for the GKE cluster's WAL archive and base backups."
  value       = google_storage_bucket.wal.name
}

output "wal_writer_service_account" {
  description = "Google service account that cnpg-db/pg-replica uses through Workload Identity."
  value       = google_service_account.writer.email
}

output "eks_reader_credential_config" {
  description = "Credential configuration (not a secret: no key) that lets pg-primary on EKS read the bucket through Workload Identity Federation."
  value = jsonencode({
    type               = "external_account"
    audience           = "//iam.googleapis.com/${local.eks_pool_name}/providers/${local.eks_provider_id}"
    subject_token_type = "urn:ietf:params:oauth:token-type:jwt"
    token_url          = "https://sts.googleapis.com/v1/token"
    # The IRSA token EKS mounts into every container of pg-primary's pods.
    credential_source = {
      file   = "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
      format = { type = "text" }
    }
  })
}
