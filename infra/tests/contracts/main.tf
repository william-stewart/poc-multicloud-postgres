# Test harness for module contracts. It deploys nothing: `tofu test` here runs
# each per-cloud implementation (via `run { module { source = ... } }`) against
# mock providers and checks that its shared outputs have the contracted shape.
#
# This complements scripts/check_module_contracts.py, which checks that inputs
# and outputs are *declared* (and input types match). These tests check the
# *values* the outputs actually produce: types, emptiness and format.

terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
  }
}
