output "state_bucket" {
  description = "Name of the S3 bucket that holds OpenTofu state for the AWS stacks."
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  description = "ARN of the KMS key that encrypts the state bucket."
  value       = aws_kms_key.state.arn
}

output "backend_config" {
  description = "Values for `tofu init -backend-config=...` in the AWS stacks (add a per-stack key)."
  value = {
    bucket       = aws_s3_bucket.state.bucket
    region       = var.aws_region
    encrypt      = true
    kms_key_id   = aws_kms_key.state.arn
    use_lockfile = true
  }
}
