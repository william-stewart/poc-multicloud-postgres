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

  # Same Kubernetes minor on both clouds. 1.36 is the newest version that is
  # both in EKS standard support (1.34-1.37) and e2e-tested by Cilium 1.20
  # (1.33-1.36). The GKE stack checks at plan time that GKE offers it.
  kubernetes = {
    version    = "1.36"
    node_count = 2
  }

  # Lowercase keys and values are valid as both AWS tags and GCP labels,
  # so one cost or inventory query works across clouds.
  labels = {
    project    = local.name_prefix
    managed-by = "opentofu"
  }
}
