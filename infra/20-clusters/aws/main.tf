module "settings" {
  source = "../../modules/settings"
}

# The network keeps its own state; find it through data sources instead of
# reading 10-network's state file.
module "network" {
  source = "../../modules/network-lookup/aws"

  name   = module.settings.name_prefix
  region = module.settings.regions.aws
}

module "cluster" {
  source = "../../modules/cluster/aws"

  name               = module.settings.name_prefix
  kubernetes_version = module.settings.kubernetes.version
  node_count         = module.settings.kubernetes.node_count
  machine_type       = var.machine_type
  api_allowed_cidrs  = var.api_allowed_cidrs

  region     = module.settings.regions.aws
  vpc_id     = module.network.network_id
  subnet_ids = module.network.private_subnet_ids

  # Tags come from the provider's default_tags.
  labels = {}
}
