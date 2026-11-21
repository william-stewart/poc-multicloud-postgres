variable "replica_egress_ips" {
  description = "Public IPs the GCP replica reaches S3 from: `tofu -chdir=infra/10-network/gcp output -json nat_egress_ips`. The reader can only be used from these."
  type        = list(string)

  validation {
    condition     = length(var.replica_egress_ips) > 0 && alltrue([for ip in var.replica_egress_ips : can(cidrhost("${ip}/32", 0)) && !strcontains(ip, "/")])
    error_message = "replica_egress_ips must list at least one IPv4 address (no CIDR ranges)."
  }
}

variable "primary_cluster_name" {
  description = "Name of the CloudNativePG Cluster on EKS. It is also its service account name and its folder in the bucket."
  type        = string
  default     = "pg-primary"
}

variable "database_namespace" {
  description = "Kubernetes namespace of the database clusters."
  type        = string
  default     = "cnpg-db"
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep overwritten or deleted backup objects (the bucket is versioned)."
  type        = number
  default     = 7
}
