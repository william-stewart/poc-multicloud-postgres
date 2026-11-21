terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # The EKS module v21 needs 6.59 or later.
      version = ">= 6.59, < 7.0"
    }
  }
}
