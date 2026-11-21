output "wal_bucket" {
  description = "S3 bucket for the WAL archive and base backups."
  value       = aws_s3_bucket.wal.bucket
}

output "wal_bucket_region" {
  description = "Region of the WAL bucket."
  value       = local.region
}

output "wal_writer_role_arn" {
  description = "IRSA role for the primary cluster's service account (cnpg-db/pg-primary)."
  value       = aws_iam_role.writer.arn
}

output "wal_reader_user" {
  description = "IAM user the GCP replica reads with. Create its access key out of band (see README)."
  value       = aws_iam_user.reader.name
}
