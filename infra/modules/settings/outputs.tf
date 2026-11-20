output "name_prefix" {
  description = "Prefix for every resource name."
  value       = local.name_prefix
}

output "regions" {
  description = "Region per cloud: { aws, gcp }."
  value       = local.regions
}

output "cidrs" {
  description = "Non-overlapping address plan: { aws_vpc, gcp_nodes, gke_pods, gke_services }."
  value       = var.cidrs
}

output "labels" {
  description = "Base labels, valid as both AWS tags and GCP labels."
  value       = local.labels
}
