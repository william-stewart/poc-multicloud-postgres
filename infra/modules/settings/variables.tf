# The address plan is a variable only so that tests can feed it bad input.
# Stacks must not override it: this default is the single source of truth.
variable "cidrs" {
  description = "Address plan for both clouds. Do not override outside tests."
  type        = map(string)
  default = {
    aws_vpc      = "10.10.0.0/16"
    gcp_nodes    = "10.20.0.0/20"
    gke_pods     = "10.21.0.0/16"
    gke_services = "10.22.0.0/20"
  }

  validation {
    condition     = alltrue([for c in values(var.cidrs) : can(cidrhost(c, 0)) && cidrhost(c, 0) == split("/", c)[0]])
    error_message = "Every entry must be a valid IPv4 network address in CIDR notation (no host bits set)."
  }

  validation {
    condition     = alltrue([for c in values(var.cidrs) : can(cidrhost(c, 0)) && cidrcontains("10.0.0.0/8", cidrhost(c, 0))])
    error_message = "Every range must sit inside 10.0.0.0/8."
  }

  # Two ranges overlap exactly when one contains the other's network address.
  validation {
    condition = length(flatten([
      for i, a in values(var.cidrs) : [
        for j, b in values(var.cidrs) : [a, b]
        if i < j && can(cidrhost(a, 0)) && can(cidrhost(b, 0)) && (cidrcontains(a, cidrhost(b, 0)) || cidrcontains(b, cidrhost(a, 0)))
      ]
    ])) == 0
    error_message = "Address ranges must not overlap, so the clouds can be joined by a VPN later."
  }
}
