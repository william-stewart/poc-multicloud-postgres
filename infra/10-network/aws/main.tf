module "settings" {
  source = "../../modules/settings"
}

module "network" {
  source = "../../modules/network/aws"

  name   = module.settings.name_prefix
  region = module.settings.regions.aws
  cidr   = module.settings.cidrs.aws_vpc

  zone_ids = module.settings.zones.aws

  # Tags come from the provider's default_tags.
  labels = {}
}
