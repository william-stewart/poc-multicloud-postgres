# Settings shared by every stack on both clouds. This module has no providers
# and no resources: it only returns constants, so any stack can call it without
# needing credentials for the other cloud.

locals {
  name_prefix = "poc-mcpg"

  regions = {
    aws = "us-east-1"
    gcp = "us-central1"
  }

  # Lowercase keys and values are valid as both AWS tags and GCP labels,
  # so one cost or inventory query works across clouds.
  labels = {
    project    = local.name_prefix
    managed-by = "opentofu"
  }
}
