variable "noncurrent_version_retention_days" {
  description = "Days to keep superseded state versions before they expire."
  type        = number
  default     = 90
}
