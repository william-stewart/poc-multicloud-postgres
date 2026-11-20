output "network_id" {
  description = "VPC ID."
  value       = module.network.network_id
}

output "network_name" {
  description = "VPC name."
  value       = module.network.network_name
}

output "private_subnet_ids" {
  description = "Private subnets for EKS nodes."
  value       = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnets for the NAT gateway and load balancers."
  value       = module.network.public_subnet_ids
}

output "nat_egress_ips" {
  description = "Public IPs that outbound traffic leaves through."
  value       = module.network.nat_egress_ips
}

output "s3_endpoint_id" {
  description = "ID of the S3 gateway endpoint."
  value       = module.network.s3_endpoint_id
}
