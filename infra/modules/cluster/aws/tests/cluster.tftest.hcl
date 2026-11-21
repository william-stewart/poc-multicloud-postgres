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
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/ABCDEF" }] }]
      certificate_authority = [{ data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t" }]
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/ABCDEF" }
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
}

# The EKS module requires tls but, with include_oidc_root_ca_thumbprint off,
# never reads from it.
mock_provider "tls" {}

variables {
  name               = "test"
  kubernetes_version = "1.36"
  node_count         = 2
  machine_type       = "m6i.large"
  node_image         = "BOTTLEROCKET_x86_64"
  api_allowed_cidrs  = ["203.0.113.7/32"]
  region             = "us-east-1"
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_ids         = ["subnet-a", "subnet-b", "subnet-c"]
  labels             = { project = "test" }
}

run "nodes_wait_for_cilium" {
  command = plan

  assert {
    condition     = local.cilium_taint == { key = "node.cilium.io/agent-not-ready", value = "true", effect = "NO_EXECUTE" }
    error_message = "Nodes must carry the Cilium agent-not-ready NoExecute taint."
  }
}

run "bottlerocket_nodes_are_hardened" {
  command = plan

  assert {
    condition     = keys(local.block_device_mappings) == tolist(["xvda", "xvdb"]) && alltrue([for d in values(local.block_device_mappings) : d.ebs.encrypted])
    error_message = "Bottlerocket needs an OS volume (xvda) and a data volume (xvdb), both encrypted."
  }

  assert {
    condition     = local.block_device_mappings.xvdb.ebs.volume_size >= 50
    error_message = "The Bottlerocket data volume holds images and container storage; it must be at least 50 GiB."
  }

  assert {
    condition = alltrue([
      for setting in [
        "[settings.host-containers.admin]\nenabled = false",
        "[settings.host-containers.control]\nenabled = false",
        "lockdown = \"integrity\"",
      ] : strcontains(local.bottlerocket_settings, setting)
    ])
    error_message = "Bottlerocket must run without admin or control containers and with kernel lockdown."
  }
}

run "al2023_uses_one_root_volume" {
  command = plan

  variables {
    node_image = "AL2023_x86_64_STANDARD"
  }

  assert {
    condition     = keys(local.block_device_mappings) == tolist(["xvda"]) && local.block_device_mappings.xvda.ebs.encrypted
    error_message = "AL2023 uses a single encrypted root volume."
  }

  assert {
    condition     = !local.is_bottlerocket
    error_message = "Bottlerocket settings must not be passed to other images."
  }
}

run "rejects_arm_image_on_x86_instances" {
  command = plan

  variables {
    node_image = "BOTTLEROCKET_ARM_64"
  }

  expect_failures = [var.node_image]
}

run "cilium_operator_writes_are_scoped" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.cilium_operator.statement : alltrue([
        for r in s.resources : startswith(r, "arn:aws:ec2:us-east-1:123456789012:")
      ]) if s.sid == "ManageENIs"
    ])
    error_message = "Cilium's mutating EC2 permissions must be limited to this account and region."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.cilium_operator.statement :
      alltrue([for a in s.actions : startswith(a, "ec2:Describe")]) if contains(s.resources, "*")
    ])
    error_message = "Only Describe calls may use Resource \"*\"."
  }
}

run "irsa_roles_trust_one_service_account_each" {
  command = plan

  assert {
    condition = (
      one([for c in data.aws_iam_policy_document.irsa_trust["cilium_operator"].statement[0].condition : c.values if endswith(c.variable, ":sub")]) == tolist(["system:serviceaccount:kube-system:cilium-operator"]) &&
      one([for c in data.aws_iam_policy_document.irsa_trust["ebs_csi"].statement[0].condition : c.values if endswith(c.variable, ":sub")]) == tolist(["system:serviceaccount:kube-system:ebs-csi-controller-sa"])
    )
    error_message = "Each IRSA role must trust exactly its own service account."
  }
}

run "rejects_api_open_to_internet" {
  command = plan

  variables {
    api_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.api_allowed_cidrs]
}

run "rejects_empty_api_allowlist" {
  command = plan

  variables {
    api_allowed_cidrs = []
  }

  expect_failures = [var.api_allowed_cidrs]
}
