variable "project_id" {
  description = "GCP project that hosts the state bucket and every GCP stack."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "region" {
  description = "GCP region for the state bucket and its KMS key."
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  description = "Short prefix for resource names and the project label."
  type        = string
  default     = "poc-mcpg"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.name_prefix))
    error_message = "name_prefix must be 3-16 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep superseded state versions before they are deleted."
  type        = number
  default     = 90
}
