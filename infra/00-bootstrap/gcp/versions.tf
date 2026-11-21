terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
  }

  # The bootstrap stack creates the remote backend, so its own state is local
  # (gitignored). It holds no secrets: only bucket and key identifiers.
}

provider "google" {
  project = var.project_id
  region  = module.settings.regions.gcp

  default_labels = merge(module.settings.labels, { stack = "00-bootstrap-gcp" })
}
