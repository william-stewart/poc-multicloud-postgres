module "settings" {
  source = "../../modules/settings"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name        = module.settings.name_prefix
  region      = module.settings.regions.aws
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "${local.name}-tfstate-${local.account_id}-${local.region}"
}

# Customer-managed key so state encryption can be audited and access to it
# revoked independently of S3 permissions.
resource "aws_kms_key" "state" {
  description             = "Encrypts OpenTofu state for ${local.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdministration"
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/${local.name}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# Access logging accepted as a PoC gap, see the checkov skip below.
# trivy:ignore:AVD-AWS-0089
resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:Server access logs need a second bucket; CloudTrail covers API access for this PoC.
  #checkov:skip=CKV_AWS_144:Cross-region replication is out of scope for a single-region PoC.
  #checkov:skip=CKV2_AWS_62:No consumer for event notifications on the state bucket.
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  # Lifecycle rules act on versions, so versioning must be in place first.
  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Refuse plaintext HTTP and anything older than TLS 1.2.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  # Ensures the public access block exists before a policy is attached.
  depends_on = [aws_s3_bucket_public_access_block.state]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOutdatedTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
      },
    ]
  })
}
