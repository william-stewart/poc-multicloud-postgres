module "settings" {
  source = "../../modules/settings"
}

locals {
  name   = module.settings.name_prefix
  region = module.settings.regions.gcp

  # The Kubernetes service account CloudNativePG runs pg-replica's instances
  # (and the Barman Cloud sidecar) under, as a Workload Identity member.
  replica_ksa = "serviceAccount:${var.project_id}.svc.id.goog[${var.database_namespace}/${var.replica_cluster_name}]"

  # Workload Identity Federation for pg-primary on EKS. The pool is long-lived
  # (00-bootstrap/gcp); the provider is per EKS cluster. Every EKS cluster
  # gets a new issuer ID, so naming the provider after it means a rebuilt
  # cluster never collides with a provider deleted less than 30 days ago.
  eks_pool_id     = "${local.name}-eks"
  eks_issuer_id   = lower(regex("[0-9A-F]{32}$", var.eks_oidc_issuer_url))
  eks_provider_id = "eks-${substr(local.eks_issuer_id, 0, 28)}"
  eks_pool_name   = "projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${local.eks_pool_id}"
  primary_subject = "system:serviceaccount:${var.database_namespace}:${var.primary_cluster_name}"
}

data "google_project" "this" {
  project_id = var.project_id
}

# --- Other stacks, found through data sources (no remote state) ---

# Long-lived key from 00-bootstrap/gcp: Cloud KMS keys can never be deleted.
data "google_kms_key_ring" "wal" {
  name     = "${local.name}-wal"
  location = local.region
}

data "google_kms_crypto_key" "wal" {
  name     = "${local.name}-wal"
  key_ring = data.google_kms_key_ring.wal.id
}

# The Cloud Storage service agent encrypts objects with the key on our behalf.
data "google_storage_project_service_account" "gcs" {}

resource "google_kms_crypto_key_iam_member" "gcs_uses_wal_key" {
  crypto_key_id = data.google_kms_crypto_key.wal.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# --- WAL bucket ---
# The GCP side's own archive. pg-replica re-archives every WAL segment it
# replays from S3 (CloudNativePG runs replica clusters with
# archive_mode=always) and takes its own base backups here. So a copy of the
# backups and WAL lives in GCP, written by a GCP identity, and a promoted
# replica keeps archiving to the same place with no change.

resource "google_storage_bucket" "wal" {
  #checkov:skip=CKV_GCP_62:Usage logs need a second bucket; Cloud Audit Logs cover access for this PoC.
  name          = "${var.project_id}-${local.name}-wal"
  location      = upper(local.region)
  storage_class = "STANDARD"

  # The PoC is torn down nightly; this lets `tofu destroy` empty the bucket.
  force_destroy = true

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = data.google_kms_crypto_key.wal.id
  }

  # Barman's retention policy deletes old base backups and WAL. Versioning keeps
  # what it deletes (or overwrites) for a short while, then this rule removes it.
  lifecycle_rule {
    condition {
      with_state                 = "ARCHIVED"
      days_since_noncurrent_time = var.noncurrent_version_retention_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  # The bucket can't use the key until the service agent has been granted it.
  depends_on = [google_kms_crypto_key_iam_member.gcs_uses_wal_key]
}

# --- Writer: pg-replica on GKE, through Workload Identity ---
# No key: the GKE metadata server hands the pod short-lived tokens for this
# service account.

resource "google_service_account" "writer" {
  account_id   = "${local.name}-wal-writer"
  display_name = "WAL archive writer (${var.database_namespace}/${var.replica_cluster_name} on GKE)"
}

resource "google_service_account_iam_member" "writer_workload_identity" {
  service_account_id = google_service_account.writer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.replica_ksa
}

# Bucket-level grants only, nothing on the project. objectUser covers
# list, read, write and delete (Barman's retention policy needs delete);
# legacyBucketReader adds storage.buckets.get for Barman's bucket check.
resource "google_storage_bucket_iam_member" "writer" {
  for_each = toset(["roles/storage.objectUser", "roles/storage.legacyBucketReader"])

  bucket = google_storage_bucket.wal.name
  role   = each.value
  member = google_service_account.writer.member
}

# --- Reader: pg-primary on EKS, through Workload Identity Federation ---
# The CloudNativePG distributed topology needs each cluster to read the
# other's archive: pg-primary reads this bucket to follow pg-replica after a
# switchover, and to be rebuilt from it after a failover. No key: Google's STS
# exchanges the pod's EKS service account token for a short-lived token.

resource "google_iam_workload_identity_pool_provider" "eks" {
  workload_identity_pool_id          = local.eks_pool_id
  workload_identity_pool_provider_id = local.eks_provider_id
  display_name                       = "EKS ${local.eks_issuer_id}"
  description                        = "Service account tokens of the ${local.name} EKS cluster"

  # Only pg-primary's service account; any other token from the cluster is
  # rejected at the exchange.
  attribute_mapping   = { "google.subject" = "assertion.sub" }
  attribute_condition = "assertion.sub == '${local.primary_subject}'"

  oidc {
    issuer_uri = var.eks_oidc_issuer_url
    # The token EKS already mounts for IRSA, so the pod needs no second one.
    # It only works for pg-primary's subject, which the IRSA writer role
    # trusts too, so accepting it grants nothing to anyone else.
    allowed_audiences = ["sts.amazonaws.com"]
  }
}

# Read-only, on this bucket only. objectViewer lists and reads objects;
# legacyBucketReader adds storage.buckets.get for Barman's bucket check.
resource "google_storage_bucket_iam_member" "eks_reader" {
  for_each = toset(["roles/storage.objectViewer", "roles/storage.legacyBucketReader"])

  bucket = google_storage_bucket.wal.name
  role   = each.value
  member = "principal://iam.googleapis.com/${local.eks_pool_name}/subject/${local.primary_subject}"

  depends_on = [google_iam_workload_identity_pool_provider.eks]
}
