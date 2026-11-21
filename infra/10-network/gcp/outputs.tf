output "network_id" {
  description = "VPC network ID."
  value       = module.network.network_id
}

output "network_name" {
  description = "VPC network name."
  value       = module.network.network_name
}

output "private_subnet_ids" {
  description = "Node subnet for GKE."
  value       = module.network.private_subnet_ids
}

output "nat_egress_ips" {
  description = "Reserved IP that outbound traffic leaves through."
  value       = module.network.nat_egress_ips
}

output "subnet_name" {
  description = "Node subnet name, for the GKE cluster."
  value       = module.network.subnet_name
}

output "pods_range_name" {
  description = "Secondary range name for GKE pods."
  value       = module.network.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for GKE services."
  value       = module.network.services_range_name
}
