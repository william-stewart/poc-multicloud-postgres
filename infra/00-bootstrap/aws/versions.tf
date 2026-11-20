terraform {
  # use_lockfile (S3-native state locking) in downstream backends needs 1.10+.
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
  }

  # The bootstrap stack creates the remote backend, so its own state is local
  # (gitignored). It holds no secrets: only bucket and key identifiers.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.name_prefix
      Stack     = "00-bootstrap"
      ManagedBy = "opentofu"
    }
  }
}
