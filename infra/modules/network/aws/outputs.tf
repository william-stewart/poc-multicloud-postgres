# --- Shared network interface (see ../contract.json) ---
# List outputs go through tolist(): the VPC module's splats return tuples, and
# the contract (infra/tests/contracts) requires lists on both clouds.

output "network_id" {
  description = "ID of the network (AWS: VPC ID)."
  value       = module.vpc.vpc_id
}

output "network_name" {
  description = "Name of the network."
  value       = module.vpc.name
}

output "private_subnet_ids" {
  description = "Subnets for cluster nodes, with no public IPs."
  value       = tolist(module.vpc.private_subnets)
}

output "nat_egress_ips" {
  description = "Public IPs that outbound traffic from private subnets leaves through."
  value       = tolist(module.vpc.nat_public_ips)
}

# --- AWS only ---

output "azs" {
  description = "Availability zones in use, in subnet order."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnets, for the NAT gateway and internet-facing load balancers."
  value       = tolist(module.vpc.public_subnets)
}

output "private_route_table_ids" {
  description = "Route tables of the private subnets."
  value       = tolist(module.vpc.private_route_table_ids)
}

output "s3_endpoint_id" {
  description = "ID of the S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}
