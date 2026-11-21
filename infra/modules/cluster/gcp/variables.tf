# --- Shared cluster interface (see ../contract.json) ---

variable "name" {
  description = "Cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, e.g. 1.36."
  type        = string
}

variable "node_count" {
  description = "Number of worker nodes."
  type        = number

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 10
    error_message = "node_count must be between 1 and 10."
  }
}

variable "machine_type" {
  description = "Worker node machine type."
  type        = string
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint (e.g. your IP as x.x.x.x/32)."
  type        = list(string)

  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && alltrue([for c in var.api_allowed_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "api_allowed_cidrs must list at least one valid CIDR, and none may be open to the whole internet (/0)."
  }
}

variable "labels" {
  description = "Labels applied to every resource that supports them."
  type        = map(string)
  default     = {}
}

# --- GCP only ---

variable "project_id" {
  description = "Project of the cluster."
  type        = string
}

variable "zone" {
  description = "Zone of the (zonal) cluster. Zonal clusters get the free control plane credit."
  type        = string
}

variable "network_id" {
  description = "VPC network ID."
  type        = string
}

variable "subnet_id" {
  description = "Node subnet ID."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range on the node subnet for pod IPs."
  type        = string
}

variable "services_range_name" {
  description = "Secondary range on the node subnet for service IPs."
  type        = string
}

variable "secrets_kms_key_id" {
  description = "Cloud KMS key for application-layer Secrets encryption (same region as the cluster)."
  type        = string
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}
