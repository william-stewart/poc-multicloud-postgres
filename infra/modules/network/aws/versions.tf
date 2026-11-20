terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Per-resource `region` arguments need provider 6.
      version = ">= 6.28, < 7.0"
    }
  }
}
