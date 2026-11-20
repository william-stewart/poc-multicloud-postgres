# --- Shared lookup interface (see ../contract.json) ---
# Lists are sorted because data sources don't guarantee an order, and an
# order change would otherwise show up as a diff downstream.

output "network_id" {
  description = "VPC ID."
  value       = data.aws_vpc.this.id
}

output "network_name" {
  description = "VPC name."
  value       = var.name
}

output "private_subnet_ids" {
  description = "Private subnets for cluster nodes."
  value       = sort(data.aws_subnets.private.ids)
}

output "nat_egress_ips" {
  description = "Public IPs that outbound traffic leaves through."
  value       = sort([for n in data.aws_nat_gateway.this : n.public_ip])
}

# --- AWS only ---

output "public_subnet_ids" {
  description = "Public subnets, for internet-facing load balancers."
  value       = sort(data.aws_subnets.public.ids)
}
