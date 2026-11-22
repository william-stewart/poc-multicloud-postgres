mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::123456789012:role/admin" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }

  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }

  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/eks/mock/cluster" }
  }

  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:us-east-1:123456789012:cluster/test"
      endpoint              = "https://ABCDEF.gr7.us-east-1.eks.amazonaws.com"
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF" }] }]
      certificate_authority = [{ data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t" }]
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF" }
  }

  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", arn = "arn:aws:ec2:us-east-1:123456789012:launch-template/lt-0123456789abcdef0" }
  }

  mock_resource "aws_security_group" {
    defaults = { id = "sg-0123456789abcdef0", arn = "arn:aws:ec2:us-east-1:123456789012:security-group/sg-0123456789abcdef0" }
  }

  # Defaults, not overrides: the EKS module reads these data sources too.
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:role/admin" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }

  # network-lookup/aws
  mock_data "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }

  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb", "subnet-0cccccccccccccccc"] }
  }

  mock_data "aws_nat_gateways" {
    defaults = { ids = ["nat-0123456789abcdef0"] }
  }

  mock_data "aws_nat_gateway" {
    defaults = { public_ip = "203.0.113.10" }
  }
}

# The EKS module requires tls but, with include_oidc_root_ca_thumbprint off,
# never reads from it.
mock_provider "tls" {}

variables {
  api_allowed_cidrs = ["203.0.113.7/32"]
}

run "wires_settings_and_network_lookup" {
  command = plan

  assert {
    condition     = length(module.network.private_subnet_ids) == 3
    error_message = "Nodes must use the private subnets found by network-lookup/aws."
  }
}

# Values later stacks and scripts depend on.
run "outputs_match_what_downstream_expects" {
  command = plan

  assert {
    condition     = output.cluster_name == "poc-mcpg"
    error_message = "30-data/aws looks the cluster up by the settings prefix."
  }

  assert {
    condition     = strcontains(output.kubeconfig_command, "--alias poc-mcpg")
    error_message = "docs/deploy.md expects the kube context to be named poc-mcpg."
  }

  # Same pattern as 30-data/gcp's eks_oidc_issuer_url validation.
  assert {
    condition     = can(regex("^https://oidc\\.eks\\.[a-z0-9-]+\\.amazonaws\\.com/id/[0-9A-F]{32}$", output.oidc_issuer_url))
    error_message = "oidc_issuer_url must be accepted by 30-data/gcp's eks_oidc_issuer_url validation."
  }
}

run "requires_an_api_allowlist" {
  command = plan

  variables {
    api_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.api_allowed_cidrs]
}
