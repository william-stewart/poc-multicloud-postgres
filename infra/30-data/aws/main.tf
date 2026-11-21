module "settings" {
  source = "../../modules/settings"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name       = module.settings.name_prefix
  region     = module.settings.regions.aws
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  bucket_name = "${local.name}-wal-${local.account_id}-${local.region}"
  # CloudNativePG writes each cluster's WAL and base backups under its name.
  primary_prefix = "${var.primary_cluster_name}/"

  oidc_issuer   = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_provider = replace(local.oidc_issuer, "https://", "")

  # IAM condition keys for an OIDC provider are its URL without the scheme.
  gke_oidc_provider = replace(var.gke_oidc_issuer_url, "https://", "")
}

# --- Other stacks, found through data sources (no remote state) ---

module "network" {
  source = "../../modules/network-lookup/aws"

  name   = local.name
  region = local.region
}

# WAL archiving reaches S3 through this gateway endpoint (10-network/aws).
data "aws_vpc_endpoint" "s3" {
  vpc_id       = module.network.network_id
  service_name = "com.amazonaws.${local.region}.s3"

  filter {
    name   = "vpc-endpoint-type"
    values = ["Gateway"]
  }
}

data "aws_eks_cluster" "this" {
  name = local.name
}

data "aws_iam_openid_connect_provider" "eks" {
  url = local.oidc_issuer
}

# --- WAL bucket ---

resource "aws_kms_key" "wal" {
  description             = "Encrypts the WAL archive and base backups for ${local.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdministration"
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

resource "aws_kms_alias" "wal" {
  name          = "alias/${local.name}-wal"
  target_key_id = aws_kms_key.wal.key_id
}

# Accepted: access logging, see the checkov skip below.
# trivy:ignore:AVD-AWS-0089
resource "aws_s3_bucket" "wal" {
  #checkov:skip=CKV_AWS_18:Server access logs need a second bucket; CloudTrail covers API access for this PoC.
  #checkov:skip=CKV_AWS_144:No S3 replication; pg-replica keeps an independent copy of the backups and WAL in GCS (infra/30-data/gcp).
  #checkov:skip=CKV2_AWS_62:No consumer for event notifications on the WAL bucket.
  bucket = local.bucket_name

  # The PoC is torn down nightly; this lets `tofu destroy` empty the bucket.
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "wal" {
  bucket = aws_s3_bucket.wal.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "wal" {
  bucket = aws_s3_bucket.wal.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "wal" {
  bucket = aws_s3_bucket.wal.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "wal" {
  bucket = aws_s3_bucket.wal.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.wal.arn
    }
    bucket_key_enabled = true
  }
}

# Barman's retention policy deletes old base backups and WAL. Versioning keeps
# what it deletes (or overwrites) for a short while, then this rule removes it.
resource "aws_s3_bucket_lifecycle_configuration" "wal" {
  bucket = aws_s3_bucket.wal.id

  depends_on = [aws_s3_bucket_versioning.wal]

  rule {
    id     = "expire-deleted-backups"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "wal" {
  bucket = aws_s3_bucket.wal.id

  depends_on = [aws_s3_bucket_public_access_block.wal]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.wal.arn, "${aws_s3_bucket.wal.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOutdatedTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.wal.arn, "${aws_s3_bucket.wal.arn}/*"]
        Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
      },
    ]
  })
}

# --- Writer: the primary cluster on EKS, through IRSA ---

data "aws_iam_policy_document" "writer_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }

    # CloudNativePG runs every instance (and its Barman Cloud sidecar) under
    # a service account named after the Cluster.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.database_namespace}:${var.primary_cluster_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "writer" {
  name               = "${local.name}-wal-writer"
  assume_role_policy = data.aws_iam_policy_document.writer_trust.json
}

data "aws_iam_policy_document" "writer" {
  statement {
    sid       = "ListOwnPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.wal.arn]

    # IfExists: Barman's HeadBucket check carries no prefix; any listing must
    # stay inside the primary's prefix.
    condition {
      test     = "StringLikeIfExists"
      variable = "s3:prefix"
      values   = [local.primary_prefix, "${local.primary_prefix}*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [data.aws_vpc_endpoint.s3.id]
    }
  }

  # DeleteObject is needed for Barman's retention policy.
  statement {
    sid       = "ReadWriteOwnPrefix"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.wal.arn}/${local.primary_prefix}*"]

    # Only from inside the VPC, through the gateway endpoint.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [data.aws_vpc_endpoint.s3.id]
    }
  }

  statement {
    sid       = "UseKeyThroughS3"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.wal.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "writer" {
  name   = "wal-archive"
  role   = aws_iam_role.writer.id
  policy = data.aws_iam_policy_document.writer.json
}

# --- Reader: the replica on GKE, through federation with GKE's OIDC issuer ---
# No key: pg-replica's pods get a short-lived Kubernetes service account token
# with the audience sts.amazonaws.com, and exchange it for this role's
# credentials with AssumeRoleWithWebIdentity, the same way IRSA works on EKS.
# The role can only read, and only from the GCP Cloud NAT IP.

resource "aws_iam_openid_connect_provider" "gke" {
  url            = var.gke_oidc_issuer_url
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "reader_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gke.arn]
    }

    # CloudNativePG runs every instance (and its Barman Cloud sidecar) under
    # a service account named after the Cluster.
    condition {
      test     = "StringEquals"
      variable = "${local.gke_oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.database_namespace}:${var.replica_cluster_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.gke_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "reader" {
  name               = "${local.name}-wal-reader"
  assume_role_policy = data.aws_iam_policy_document.reader_trust.json
}

data "aws_iam_policy_document" "reader" {
  statement {
    sid       = "ListPrimaryPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.wal.arn]

    # IfExists: Barman's HeadBucket check carries no prefix; any listing must
    # stay inside the primary's prefix.
    condition {
      test     = "StringLikeIfExists"
      variable = "s3:prefix"
      values   = [local.primary_prefix, "${local.primary_prefix}*"]
    }

    condition {
      test     = "IpAddress"
      variable = "aws:SourceIp"
      values   = [for ip in var.replica_egress_ips : "${ip}/32"]
    }
  }

  statement {
    sid       = "ReadPrimaryPrefix"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.wal.arn}/${local.primary_prefix}*"]

    condition {
      test     = "IpAddress"
      variable = "aws:SourceIp"
      values   = [for ip in var.replica_egress_ips : "${ip}/32"]
    }
  }

  statement {
    sid       = "DecryptThroughS3"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.wal.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "reader" {
  name   = "wal-read-only"
  role   = aws_iam_role.reader.id
  policy = data.aws_iam_policy_document.reader.json
}
