output "name_prefix" {
  description = "Prefix for every resource name."
  value       = local.name_prefix
}

output "regions" {
  description = "Region per cloud: { aws, gcp }."
  value       = local.regions
}

output "zones" {
  description = "Zones per cloud: { aws = [zone IDs], gcp = zone }."
  value       = local.zones
}

output "cidrs" {
  description = "Non-overlapping address plan: { aws_vpc, gcp_nodes, gke_pods, gke_services }."
  value       = var.cidrs
}

output "kubernetes" {
  description = "Cluster settings: { version, node_count, node_image = { aws, gcp } }."
  value       = local.kubernetes
}

output "labels" {
  description = "Base labels, valid as both AWS tags and GCP labels."
  value       = local.labels
}
