module "settings" {
  source = "../../modules/settings"
}

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_service" "container" {
  service = "container.googleapis.com"

  # Other stacks may depend on the API; never switch it off on destroy.
  disable_on_destroy = false
}

# The network keeps its own state; find it through data sources instead of
# reading 10-network's state file.
module "network" {
  source = "../../modules/network-lookup/gcp"

  name       = module.settings.name_prefix
  region     = module.settings.regions.gcp
  project_id = var.project_id
}

# The Secrets encryption key is long-lived and lives in 00-bootstrap/gcp,
# because Cloud KMS keys can never be deleted.
data "google_kms_key_ring" "gke" {
  name     = "${module.settings.name_prefix}-gke"
  location = module.settings.regions.gcp
}

data "google_kms_crypto_key" "gke_secrets" {
  name     = "${module.settings.name_prefix}-gke-secrets"
  key_ring = data.google_kms_key_ring.gke.id
}

# The GKE service agent encrypts and decrypts Secrets with the key. The grant
# is destroyed with the cluster; the key stays.
resource "google_kms_crypto_key_iam_member" "gke_secrets" {
  crypto_key_id = data.google_kms_crypto_key.gke_secrets.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@container-engine-robot.iam.gserviceaccount.com"

  # The service agent only exists once the Kubernetes Engine API is on.
  depends_on = [google_project_service.container]
}

module "cluster" {
  source = "../../modules/cluster/gcp"

  name               = module.settings.name_prefix
  kubernetes_version = module.settings.kubernetes.version
  node_count         = module.settings.kubernetes.node_count
  machine_type       = var.machine_type
  node_image         = module.settings.kubernetes.node_image.gcp
  api_allowed_cidrs  = var.api_allowed_cidrs

  project_id          = var.project_id
  zone                = module.settings.zones.gcp
  network_id          = module.network.network_id
  subnet_id           = one(module.network.private_subnet_ids)
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name

  # Referencing the grant (not the key directly) makes the cluster wait for it.
  secrets_kms_key_id = google_kms_crypto_key_iam_member.gke_secrets.crypto_key_id

  # Passed explicitly (as well as through default_labels) so they are visible
  # in the configuration, where scanners and reviewers look for them.
  labels = merge(module.settings.labels, { stack = "20-clusters-gcp" })
}
