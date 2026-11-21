terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
  }

  # Partial configuration: bucket, region and kms_key_id come from the
  # 00-bootstrap/aws outputs at init time (see README).
  backend "s3" {
    key          = "30-data/aws/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = module.settings.regions.aws

  default_tags {
    tags = merge(module.settings.labels, { stack = "30-data-aws" })
  }
}
