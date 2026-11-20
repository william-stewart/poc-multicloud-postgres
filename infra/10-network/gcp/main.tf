module "settings" {
  source = "../../modules/settings"
}

resource "google_project_service" "compute" {
  service = "compute.googleapis.com"

  # Later stacks depend on this API; never switch it off on destroy.
  disable_on_destroy = false
}

module "network" {
  source = "../../modules/network/gcp"

  name   = module.settings.name_prefix
  region = module.settings.regions.gcp
  cidr   = module.settings.cidrs.gcp_nodes

  project_id    = var.project_id
  pods_cidr     = module.settings.cidrs.gke_pods
  services_cidr = module.settings.cidrs.gke_services

  # Labels come from the provider's default_labels.
  labels = {}

  depends_on = [google_project_service.compute]
}
