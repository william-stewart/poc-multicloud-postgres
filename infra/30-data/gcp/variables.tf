variable "project_id" {
  description = "GCP project of the GKE cluster and the WAL bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "eks_oidc_issuer_url" {
  description = "OIDC issuer of the EKS cluster: `tofu -chdir=infra/20-clusters/aws output -raw oidc_issuer_url`. pg-primary's service account on it may read the bucket."
  type        = string

  validation {
    condition     = can(regex("^https://oidc\\.eks\\.[a-z0-9-]+\\.amazonaws\\.com/id/[0-9A-F]{32}$", var.eks_oidc_issuer_url))
    error_message = "eks_oidc_issuer_url must be an EKS OIDC issuer URL (https://oidc.eks.<region>.amazonaws.com/id/<32 hex characters>)."
  }
}

variable "primary_cluster_name" {
  description = "Name of the CloudNativePG Cluster on EKS, which is also its service account name."
  type        = string
  default     = "pg-primary"
}

variable "replica_cluster_name" {
  description = "Name of the CloudNativePG Cluster on GKE. It is also its service account name and its folder in the bucket."
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
