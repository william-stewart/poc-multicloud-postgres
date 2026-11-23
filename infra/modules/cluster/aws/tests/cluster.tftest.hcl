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

# Assert on what the node group receives (local.default_node_group) and on
# what the EKS module reports back, not on the constants they are built from:
# dropping the wiring must fail these tests.
run "nodes_wait_for_cilium" {
  command = plan

  assert {
    condition     = local.default_node_group.taints == { cilium = { key = "node.cilium.io/agent-not-ready", value = "true", effect = "NO_EXECUTE" } }
    error_message = "The node group must carry the Cilium agent-not-ready NoExecute taint."
  }

  assert {
    condition = anytrue([
      for t in module.eks.eks_managed_node_groups["default"].node_group_taints :
      t.key == "node.cilium.io/agent-not-ready" && t.effect == "NO_EXECUTE"
    ])
    error_message = "The EKS node group must be created with the Cilium taint."
  }
}

run "node_group_starts_empty_and_is_private" {
  command = plan

  # Created empty so tofu apply doesn't wait on nodes that can't be Ready
  # before Cilium; make bootstrap scales it to node_count.
  assert {
    condition = (
      local.default_node_group.min_size == 0 &&
      local.default_node_group.max_size == 2 &&
      local.default_node_group.desired_size == 0
    )
    error_message = "The node group must start empty, with room for node_count nodes."
  }

  assert {
    condition     = output.node_count == 2
    error_message = "make bootstrap scales the node group to node_count, so it must be output."
  }

  assert {
    condition     = local.default_node_group.instance_types == ["m6i.large"] && local.default_node_group.ami_type == "BOTTLEROCKET_x86_64"
    error_message = "The node group must use machine_type and node_image."
  }

  assert {
    condition     = local.default_node_group.subnet_ids == tolist(["subnet-a", "subnet-b", "subnet-c"])
    error_message = "Nodes must run in the private subnets passed in."
  }

  assert {
    condition     = !local.default_node_group.iam_role_attach_cni_policy
    error_message = "The node role must not get the VPC CNI policy; Cilium has its own IRSA role."
  }
}

run "bottlerocket_nodes_are_hardened" {
  command = plan

  assert {
    condition = (
      keys(local.default_node_group.block_device_mappings) == tolist(["xvda", "xvdb"]) &&
      alltrue([for d in values(local.default_node_group.block_device_mappings) : d.ebs.encrypted])
    )
    error_message = "Bottlerocket needs an OS volume (xvda) and a data volume (xvdb), both encrypted."
  }

  assert {
    condition     = local.default_node_group.block_device_mappings.xvdb.ebs.volume_size >= 50
    error_message = "The Bottlerocket data volume holds images and container storage; it must be at least 50 GiB."
  }

  assert {
    condition = alltrue([
      for setting in [
        "[settings.host-containers.admin]\nenabled = false",
        "[settings.host-containers.control]\nenabled = false",
        "lockdown = \"integrity\"",
      ] : strcontains(local.default_node_group.bootstrap_extra_args, setting)
    ])
    error_message = "Bottlerocket nodes must get settings with no admin or control container and with kernel lockdown."
  }
}

run "al2023_uses_one_root_volume" {
  command = plan

  variables {
    node_image = "AL2023_x86_64_STANDARD"
  }

  assert {
    condition     = keys(local.default_node_group.block_device_mappings) == tolist(["xvda"]) && local.default_node_group.block_device_mappings.xvda.ebs.encrypted
    error_message = "AL2023 uses a single encrypted root volume."
  }

  assert {
    condition     = local.default_node_group.bootstrap_extra_args == null
    error_message = "Bottlerocket TOML settings must not be passed to other images."
  }
}

run "control_plane_matches_inputs" {
  command = plan

  assert {
    condition     = module.eks.cluster_name == "test" && module.eks.cluster_version == "1.36"
    error_message = "The cluster must use the name and Kubernetes version passed in."
  }

  assert {
    condition     = module.eks.cloudwatch_log_group_name == "/aws/eks/test/cluster"
    error_message = "Control plane logs must go to the module-managed log group."
  }

  assert {
    condition     = length(module.eks.cluster_addons) == 0
    error_message = "No EKS add-ons: Cilium, CoreDNS and the EBS CSI driver come from k8s/."
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

run "irsa_roles_accept_only_sts_tokens" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["cilium_operator", "ebs_csi"] :
      one([for c in data.aws_iam_policy_document.irsa_trust[k].statement[0].condition : c.values if endswith(c.variable, ":aud")]) == tolist(["sts.amazonaws.com"])
    ])
    error_message = "IRSA roles must only accept tokens minted for AWS STS."
  }

  assert {
    condition = alltrue([
      for k in ["cilium_operator", "ebs_csi"] :
      alltrue([for c in data.aws_iam_policy_document.irsa_trust[k].statement[0].condition : startswith(c.variable, "oidc.eks.us-east-1.amazonaws.com/id/")])
    ])
    error_message = "IRSA condition keys must be the cluster's OIDC provider without https://."
  }
}

run "irsa_roles_get_their_permissions" {
  command = plan

  assert {
    condition     = aws_iam_role_policy_attachment.ebs_csi.policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    error_message = "The EBS CSI role must get the AWS-managed EBS CSI driver policy (exact ARN)."
  }

  # Cilium ENI IPAM fails to allocate pod IPs if any of these is missing.
  assert {
    condition = toset(flatten([for s in data.aws_iam_policy_document.cilium_operator.statement : tolist(s.actions)])) == toset([
      "ec2:DescribeInstanceTypes", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets", "ec2:DescribeVpcs",
      "ec2:DescribeRouteTables", "ec2:DescribeSecurityGroups", "ec2:DescribeTags",
      "ec2:CreateNetworkInterface", "ec2:AttachNetworkInterface", "ec2:DeleteNetworkInterface",
      "ec2:ModifyNetworkInterfaceAttribute", "ec2:AssignPrivateIpAddresses", "ec2:CreateTags",
    ])
    error_message = "The Cilium operator policy must grant exactly Cilium's ENI IPAM permissions."
  }

  assert {
    condition     = alltrue([for k, r in aws_iam_role.irsa : length(r.name) <= 64])
    error_message = "IAM role names must be at most 64 characters."
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
