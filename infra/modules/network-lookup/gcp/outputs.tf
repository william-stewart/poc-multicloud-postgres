# --- Shared lookup interface (see ../contract.json) ---

output "network_id" {
  description = "VPC network ID."
  value       = data.google_compute_network.this.id
}

output "network_name" {
  description = "VPC network name."
  value       = data.google_compute_network.this.name
}

output "private_subnet_ids" {
  description = "Node subnet for GKE."
  value       = tolist([data.google_compute_subnetwork.nodes.id])
}

output "nat_egress_ips" {
  description = "Reserved IP that outbound traffic leaves through."
  value       = tolist([data.google_compute_address.nat.address])
}

# --- GCP only ---

output "subnet_name" {
  description = "Node subnet name, as GKE expects it."
  value       = data.google_compute_subnetwork.nodes.name
}

output "pods_range_name" {
  description = "Secondary range name for GKE pods."
  value       = local.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for GKE services."
  value       = local.services_range_name
}
