# --- Shared network interface (see ../contract.json) ---

output "network_id" {
  description = "ID of the network (GCP: projects/<project>/global/networks/<name>)."
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "Name of the network."
  value       = google_compute_network.this.name
}

output "private_subnet_ids" {
  description = "Subnets for cluster nodes, with no public IPs."
  value       = tolist([google_compute_subnetwork.nodes.id])
}

output "nat_egress_ips" {
  description = "Public IPs that outbound traffic from private subnets leaves through."
  value       = tolist([google_compute_address.nat.address])
}

# --- GCP only ---

output "subnet_name" {
  description = "Name of the node subnet, as GKE expects it."
  value       = google_compute_subnetwork.nodes.name
}

output "pods_range_name" {
  description = "Name of the secondary range for GKE pods."
  value       = google_compute_subnetwork.nodes.secondary_ip_range[0].range_name
}

output "services_range_name" {
  description = "Name of the secondary range for GKE services."
  value       = google_compute_subnetwork.nodes.secondary_ip_range[1].range_name
}
