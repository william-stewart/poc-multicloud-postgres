variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint, e.g. [\"<your IP>/32\"]. Never 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && alltrue([for c in var.api_allowed_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "api_allowed_cidrs must list at least one valid CIDR, and none may be open to the whole internet (/0)."
  }
}

variable "machine_type" {
  description = "Worker node instance type."
  type        = string
  default     = "m6i.large"
}
