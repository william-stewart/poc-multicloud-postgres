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
  description = "Primary address range for nodes (AWS: the VPC CIDR)."
  type        = string
}

variable "labels" {
  description = "Labels applied to every resource (AWS: tags)."
  type        = map(string)
  default     = {}
}

# --- AWS only ---

variable "zone_ids" {
  description = "AZ IDs (e.g. use1-az1) to span, each with one private and one public subnet. IDs are the same in every account; names are not."
  type        = list(string)

  validation {
    condition     = length(var.zone_ids) >= 2 && length(var.zone_ids) <= 6 && length(distinct(var.zone_ids)) == length(var.zone_ids)
    error_message = "zone_ids must list 2 (EKS minimum) to 6 distinct AZ IDs."
  }
}

variable "flow_log_retention_days" {
  description = "Days to keep VPC flow logs in CloudWatch."
  type        = number
  default     = 30
}
