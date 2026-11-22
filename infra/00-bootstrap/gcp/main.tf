module "settings" {
  source = "../../modules/settings"
}

locals {
  name   = module.settings.name_prefix
  region = module.settings.regions.gcp
}

resource "google_project_service" "this" {
  # iam and sts: Workload Identity Federation for EKS (below).
  # container: 20-clusters/gcp reads GKE's available versions at plan time,
  # before anything in that stack could enable the API.
  for_each = toset(["cloudkms.googleapis.com", "storage.googleapis.com", "iam.googleapis.com", "sts.googleapis.com", "container.googleapis.com"])

  service = each.value

  # Other stacks depend on these APIs; never switch them off on destroy.
  disable_on_destroy = false
}

# Customer-managed key so state encryption can be audited and access to it
# revoked independently of bucket IAM. Key rings cannot be deleted in GCP.
resource "google_kms_key_ring" "state" {
  name     = "${local.name}-tfstate"
  location = local.region

  depends_on = [google_project_service.this]
}

resource "google_kms_crypto_key" "state" {
  name            = "${local.name}-tfstate"
  key_ring        = google_kms_key_ring.state.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# Key for GKE application-layer secrets encryption. It lives here, not in
# 20-clusters/gcp, because Cloud KMS key rings and keys can never be deleted:
# a nightly teardown of the cluster stack would leave the names taken and break
# the next apply. The cluster stack grants the GKE service agent access to it.
resource "google_kms_key_ring" "gke" {
  name     = "${local.name}-gke"
  location = local.region

  depends_on = [google_project_service.this]
}

resource "google_kms_crypto_key" "gke_secrets" {
  name            = "${local.name}-gke-secrets"
  key_ring        = google_kms_key_ring.gke.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# Key for the GCP WAL archive bucket (infra/30-data/gcp). Long-lived for the
# same reason as the GKE key; 30-data/gcp grants the Cloud Storage service agent
# access to it and the grant goes with the bucket.
resource "google_kms_key_ring" "wal" {
  name     = "${local.name}-wal"
  location = local.region

  depends_on = [google_project_service.this]
}

resource "google_kms_crypto_key" "wal" {
  name            = "${local.name}-wal"
  key_ring        = google_kms_key_ring.wal.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# Lets workloads on EKS act in GCP without a key: 30-data/gcp adds a provider
# that trusts the EKS cluster's OIDC issuer. The pool lives here because a
# deleted pool's ID can't be reused for 30 days, which a nightly teardown
# would hit.
resource "google_iam_workload_identity_pool" "eks" {
  workload_identity_pool_id = "${local.name}-eks"
  display_name              = "EKS workloads"
  description               = "Kubernetes service accounts on the ${local.name} EKS cluster"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this]
}

# The Cloud Storage service agent encrypts objects with the key on our behalf.
# No depends_on: it would defer the read to apply time, and the Storage API is
# enabled by default in every project.
data "google_storage_project_service_account" "gcs" {}

resource "google_kms_crypto_key_iam_member" "gcs_uses_state_key" {
  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

resource "google_storage_bucket" "state" {
  #checkov:skip=CKV_GCP_62:Usage logs need a second bucket; Cloud Audit Logs cover access for this PoC.
  name          = "${var.project_id}-${local.name}-tfstate"
  location      = upper(local.region)
  storage_class = "STANDARD"
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.state.id
  }

  lifecycle_rule {
    condition {
      with_state                 = "ARCHIVED"
      days_since_noncurrent_time = var.noncurrent_version_retention_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  # The bucket can't use the key until the service agent has been granted it.
  depends_on = [google_kms_crypto_key_iam_member.gcs_uses_state_key]
}
