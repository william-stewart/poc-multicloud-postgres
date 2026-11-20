# Settings shared by every stack on both clouds. This module has no providers
# and no resources: it only returns constants, so any stack can call it without
# needing credentials for the other cloud.

locals {
  name_prefix = "poc-mcpg"

  regions = {
    aws = "us-east-1"
    gcp = "us-central1"
  }

  # AWS zone IDs, unlike zone names, mean the same physical zone in every
  # account. use1-az3 is skipped because EKS doesn't support it. GKE is zonal
  # for this PoC (free control plane), so GCP has a single zone.
  zones = {
    aws = ["use1-az1", "use1-az2", "use1-az4"]
    gcp = "us-central1-a"
  }

  # Lowercase keys and values are valid as both AWS tags and GCP labels,
  # so one cost or inventory query works across clouds.
  labels = {
    project    = local.name_prefix
    managed-by = "opentofu"
  }
}
