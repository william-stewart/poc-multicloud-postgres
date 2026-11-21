variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint, e.g. [\"<your IP>/32\"]. Never 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && alltrue([for c in var.api_allowed_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "api_allowed_cidrs must list at least one valid CIDR, and none may be open to the whole internet (/0)."
  }
}

# 4 vCPU, like GKE's e2-standard-4. Each PostgreSQL pod takes 1.5 CPU
# (postgres 1 + Barman sidecar 0.5, Guaranteed QoS), which leaves too little
# of a 2-vCPU node for Cilium, CoreDNS, Flux and the operators.
variable "machine_type" {
  description = "Worker node instance type."
  type        = string
  default     = "m6i.xlarge"
}
