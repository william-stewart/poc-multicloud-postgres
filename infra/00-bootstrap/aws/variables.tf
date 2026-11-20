variable "aws_region" {
  description = "AWS region for the state bucket and every AWS stack."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Short prefix for resource names and the Project tag."
  type        = string
  default     = "poc-mcpg"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.name_prefix))
    error_message = "name_prefix must be 3-16 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep superseded state versions before they expire."
  type        = number
  default     = 90
}
