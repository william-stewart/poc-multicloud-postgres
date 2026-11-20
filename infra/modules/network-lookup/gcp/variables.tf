# --- Shared lookup interface (see ../contract.json) ---

variable "name" {
  description = "Name the network was built with (the settings name prefix)."
  type        = string
}

variable "region" {
  description = "Region of the node subnet and NAT."
  type        = string
}

# --- GCP only ---

variable "project_id" {
  description = "Project the network is in."
  type        = string
}
