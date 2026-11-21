variable "project_id" {
  description = "GCP project that hosts the state bucket and every GCP stack."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep superseded state versions before they are deleted."
  type        = number
  default     = 90
}
