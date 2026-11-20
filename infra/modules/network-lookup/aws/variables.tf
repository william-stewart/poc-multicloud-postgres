# --- Shared lookup interface (see ../contract.json) ---

variable "name" {
  description = "Name the network was built with (the settings name prefix)."
  type        = string
}

variable "region" {
  description = "Region the network is in."
  type        = string
}
