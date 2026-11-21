variable "replica_egress_ips" {
  description = "Public IPs the GCP replica reaches S3 from: `tofu -chdir=infra/10-network/gcp output -json nat_egress_ips`. The reader can only be used from these."
  type        = list(string)

  validation {
    condition     = length(var.replica_egress_ips) > 0 && alltrue([for ip in var.replica_egress_ips : can(cidrhost("${ip}/32", 0)) && !strcontains(ip, "/")])
    error_message = "replica_egress_ips must list at least one IPv4 address (no CIDR ranges)."
  }
}

variable "gke_oidc_issuer_url" {
  description = "OIDC issuer of the GKE cluster: `tofu -chdir=infra/20-clusters/gcp output -raw oidc_issuer_url`. pg-replica's service account on it may assume the reader role."
  type        = string

  validation {
    condition     = can(regex("^https://container\\.googleapis\\.com/v1/projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/locations/[a-z0-9-]+/clusters/[a-z0-9-]+$", var.gke_oidc_issuer_url))
    error_message = "gke_oidc_issuer_url must be a GKE cluster's issuer (https://container.googleapis.com/v1/projects/<project>/locations/<location>/clusters/<name>)."
  }
}

variable "primary_cluster_name" {
  description = "Name of the CloudNativePG Cluster on EKS. It is also its service account name and its folder in the bucket."
  type        = string
  default     = "pg-primary"
}

variable "replica_cluster_name" {
  description = "Name of the CloudNativePG Cluster on GKE, which is also its service account name."
  type        = string
  default     = "pg-replica"
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
