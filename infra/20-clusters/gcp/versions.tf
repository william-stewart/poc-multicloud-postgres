terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
  }

  # Partial configuration: bucket comes from the 00-bootstrap/gcp outputs at
  # init time (see README).
  backend "gcs" {
    prefix = "20-clusters/gcp"
  }
}

provider "google" {
  project = var.project_id
  region  = module.settings.regions.gcp

  default_labels = merge(module.settings.labels, { stack = "20-clusters-gcp" })
}
