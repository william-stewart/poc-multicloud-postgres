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
  description = "Worker node instance type."
  type        = string
}

variable "node_image" {
  description = "Node OS, as an EKS ami_type. x86_64 only, to match the instance type."
  type        = string

  validation {
    condition     = contains(["BOTTLEROCKET_x86_64", "BOTTLEROCKET_x86_64_FIPS", "AL2023_x86_64_STANDARD"], var.node_image)
    error_message = "node_image must be BOTTLEROCKET_x86_64, BOTTLEROCKET_x86_64_FIPS or AL2023_x86_64_STANDARD."
  }
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
  description = "Labels applied to every resource (AWS: tags)."
  type        = map(string)
  default     = {}
}

# --- AWS only ---

variable "region" {
  description = "Region of the cluster."
  type        = string
}

variable "vpc_id" {
  description = "VPC to run the cluster in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the control plane ENIs and the nodes (at least 2 AZs)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS needs subnets in at least 2 AZs."
  }
}

variable "log_retention_days" {
  description = "Days to keep control plane logs in CloudWatch."
  type        = number
  default     = 30
}
