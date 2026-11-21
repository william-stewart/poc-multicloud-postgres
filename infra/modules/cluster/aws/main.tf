data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Nodes start tainted so no pod schedules until the Cilium agent is ready
  # on them; Cilium removes the taint itself.
  cilium_taint = {
    key    = "node.cilium.io/agent-not-ready"
    value  = "true"
    effect = "NO_EXECUTE"
  }
}

# Accepted trivy findings:
# - AVD-AWS-0040: the public endpoint is needed to run kubectl and helm from a
#   laptop. It is limited to api_allowed_cidrs, which rejects /0 (tested). A
#   private-only endpoint would need a bastion or VPN, out of scope for the PoC.
# - AVD-AWS-0104: nodes need outbound internet through NAT for images. In
#   Cilium ENI mode pods share the node security group, so egress is filtered
#   per workload by Cilium policies instead (default deny + FQDN rules).
# trivy:ignore:AVD-AWS-0040
# trivy:ignore:AVD-AWS-0104
module "eks" {
  #checkov:skip=CKV_AWS_338:Control plane logs are kept 30 days; the PoC is torn down nightly. Production would keep a year.
  #checkov:skip=CKV_AWS_39:The public endpoint is needed to run kubectl and helm from a laptop; it is limited to api_allowed_cidrs, which rejects /0.
  #checkov:skip=CKV_AWS_38:False positive. endpoint_public_access_cidrs is var.api_allowed_cidrs, whose validation rejects /0 (tests/cluster.tftest.hcl).
  #checkov:skip=CKV_AWS_58:False positive. encryption_config below enables envelope encryption of secrets; checkov can't resolve the module's dynamic block.
  #checkov:skip=CKV2_AWS_5:False positive. The node security group is attached through the node group's launch template; the other flagged groups belong to submodules disabled with count = 0.
  #checkov:skip=CKV_TF_1:The EKS module pins its nested KMS module by registry version; this module itself is pinned by commit.
  # v21.30.2, pinned to the commit because git tags can be moved.
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=25c846a384bc66d16cc801d2f851431deb38de5d"

  name               = var.name
  kubernetes_version = var.kubernetes_version
  region             = var.region

  vpc_id                   = var.vpc_id
  subnet_ids               = var.subnet_ids
  control_plane_subnet_ids = var.subnet_ids

  # No EKS add-ons at all: v21 always creates the cluster with
  # bootstrap_self_managed_addons = false, so the VPC CNI, kube-proxy and
  # CoreDNS are never installed. Cilium and CoreDNS come from Helm (k8s/).
  addons = {}

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  # Access entries only (no aws-auth ConfigMap). Whoever applies the stack
  # gets cluster admin, so they can install the platform layer.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  enable_irsa = true
  # IAM validates EKS's OIDC issuer against its own trusted CAs and ignores
  # thumbprints, so skip fetching the issuer's certificate during apply.
  include_oidc_root_ca_thumbprint = false

  # Envelope-encrypt Kubernetes Secrets with a module-created KMS key.
  create_kms_key                  = true
  kms_key_deletion_window_in_days = 7
  encryption_config               = { resources = ["secrets"] }

  enabled_log_types                      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  # Torn down nightly.
  deletion_protection = false

  # The recommended rules already allow node-to-node TCP 1025-65535 (Cilium
  # health 4240, Hubble 4244, Postgres 5432) and control plane webhooks.
  # Cilium health checks also use ICMP between nodes.
  node_security_group_additional_rules = {
    ingress_self_icmp = {
      description = "Node to node ICMP (Cilium health checks)"
      protocol    = "icmp"
      from_port   = -1
      to_port     = -1
      type        = "ingress"
      self        = true
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.machine_type]
      subnet_ids     = var.subnet_ids

      min_size     = var.node_count
      max_size     = var.node_count
      desired_size = var.node_count

      taints = { cilium = local.cilium_taint }

      # The Cilium operator manages ENIs through its own IRSA role (below),
      # so the node role doesn't need the VPC CNI policy.
      iam_role_attach_cni_policy = false

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
      # IMDSv2 is required and the hop limit is 1 by default, so pods can't
      # reach the node's instance credentials.
    }
  }

  tags = var.labels
}

# --- IRSA roles for in-cluster components installed later with Helm ---

locals {
  oidc_provider = module.eks.oidc_provider # issuer without https://

  irsa_service_accounts = {
    cilium_operator = "system:serviceaccount:kube-system:cilium-operator"
    ebs_csi         = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
  }
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = local.irsa_service_accounts

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = [each.value]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = local.irsa_service_accounts

  name               = "${var.name}-${replace(each.key, "_", "-")}"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[each.key].json
  tags               = var.labels
}

# Cilium ENI IPAM "Required Privileges" (docs.cilium.io, Cilium 1.20), plus
# DescribeTags for ENI garbage collection, which is on by default. Describe
# calls can't be scoped to resources; every mutating call is limited to ENIs,
# subnets, security groups and instances in this account and region.
data "aws_iam_policy_document" "cilium_operator" {
  statement {
    sid = "Describe"
    actions = [
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ManageENIs"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:AttachNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:ModifyNetworkInterfaceAttribute",
      "ec2:AssignPrivateIpAddresses",
      "ec2:CreateTags",
    ]
    resources = [
      for type in ["network-interface", "subnet", "security-group", "instance"] :
      "arn:${local.partition}:ec2:${var.region}:${local.account_id}:${type}/*"
    ]
  }
}

resource "aws_iam_role_policy" "cilium_operator" {
  name   = "cilium-eni-ipam"
  role   = aws_iam_role.irsa["cilium_operator"].id
  policy = data.aws_iam_policy_document.cilium_operator.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.irsa["ebs_csi"].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
