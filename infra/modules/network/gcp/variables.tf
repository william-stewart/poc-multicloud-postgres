# --- Shared network interface (see ../contract.json) ---

variable "name" {
  description = "Name for the network and prefix for its resources."
  type        = string
}

variable "region" {
  description = "Region to build the network in."
  type        = string
}

variable "cidr" {
  description = "Primary address range for nodes (GCP: the node subnet's primary range)."
  type        = string
}

variable "labels" {
  description = "Labels applied to every resource that supports them."
  type        = map(string)
  default     = {}
}

# --- GCP only ---

variable "project_id" {
  description = "Project to build the network in."
  type        = string
}

variable "pods_cidr" {
  description = "Secondary range for GKE pod IPs."
  type        = string
}

variable "services_cidr" {
  description = "Secondary range for GKE service IPs."
  type        = string
}

variable "flow_log_sampling" {
  description = "Fraction of subnet flows to log, from 0 to 1."
  type        = number
  default     = 0.5

  validation {
    condition     = var.flow_log_sampling > 0 && var.flow_log_sampling <= 1
    error_message = "flow_log_sampling must be greater than 0 and at most 1."
  }
}
