variable "project_id" {
  description = "GCP project of the cluster."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the GKE API endpoint, e.g. [\"<your IP>/32\"]. Never 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && alltrue([for c in var.api_allowed_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "api_allowed_cidrs must list at least one valid CIDR, and none may be open to the whole internet (/0)."
  }
}

variable "machine_type" {
  description = "Worker node machine type."
  type        = string
  default     = "e2-standard-4"
}
