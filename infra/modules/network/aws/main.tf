data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Pinned to explicit zone IDs, so the set can't change when AWS adds a zone.
data "aws_availability_zones" "available" {
  region = var.region
  state  = "available"

  filter {
    name   = "zone-id"
    values = var.zone_ids
  }

  lifecycle {
    postcondition {
      condition     = length(self.zone_ids) == length(var.zone_ids)
      error_message = "Not every requested zone ID is available in this region."
    }
  }
}

locals {
  # Order follows var.zone_ids, not the data source's sort order.
  azs = [for id in var.zone_ids : data.aws_availability_zones.available.names[index(data.aws_availability_zones.available.zone_ids, id)]]

  # Private /19s are large because Cilium in ENI mode gives every pod a VPC IP.
  # Public /24s come after them and only hold the NAT gateway and load balancers.
  private_subnets = [for i in range(length(var.zone_ids)) : cidrsubnet(var.cidr, 3, i)]
  public_subnets  = [for i in range(length(var.zone_ids)) : cidrsubnet(var.cidr, 8, length(var.zone_ids) * 32 + i)]

  # `tier` is what downstream stacks look subnets up by (see
  # modules/network-lookup/aws). The kubernetes.io tags let the AWS Load
  # Balancer Controller find the subnets.
  public_subnet_tags  = { tier = "public", "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { tier = "private", "kubernetes.io/role/internal-elb" = "1" }
}

module "vpc" {
  #checkov:skip=CKV_AWS_338:Flow logs are kept 30 days; the PoC is torn down nightly. Production would keep a year.
  #checkov:skip=CKV2_AWS_12:False positive. The default SG is stripped by aws_default_security_group.this below, which checkov can't link across the module boundary; tests/network.tftest.hcl asserts it has no rules.
  # v6.8.0, pinned to the commit because git tags can be moved.
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=577ad620abe00da27a3a0f1e5acee041959fb3be"

  name   = var.name
  region = var.region
  cidr   = var.cidr
  azs    = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  public_subnet_tags  = local.public_subnet_tags
  private_subnet_tags = local.private_subnet_tags

  # One NAT gateway for the PoC. Production would use one per AZ.
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames    = true
  enable_dns_support      = true
  map_public_ip_on_launch = false

  # The default security group is managed below, where tests can see it.
  manage_default_security_group = false

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_traffic_type                           = "ALL"
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = aws_kms_key.flow_logs.arn

  tags = var.labels
}

# Adopt the VPC's default security group and strip every rule from it, so
# nothing that falls back to it by accident gets any network access.
resource "aws_default_security_group" "this" {
  region = var.region
  vpc_id = module.vpc.vpc_id

  tags = merge(var.labels, { Name = "${var.name}-default-deny" })
}

# WAL archiving to S3 goes through this gateway endpoint instead of the NAT
# gateway: it's free, and the traffic stays on the AWS network. The default
# (full access) policy stays because nodes also pull ECR image layers from S3.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  region            = var.region
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(var.labels, { Name = "${var.name}-s3" })
}

# Customer-managed key for flow logs, usable only by CloudWatch Logs in this
# account and region, and only for this VPC's log groups.
resource "aws_kms_key" "flow_logs" {
  description             = "Encrypts VPC flow logs for ${var.name}"
  region                  = var.region
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogsUse"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.region}.amazonaws.com" }
        Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc-flow-log/*"
          }
        }
      },
    ]
  })

  tags = var.labels
}

resource "aws_kms_alias" "flow_logs" {
  name          = "alias/${var.name}-vpc-flow-logs"
  region        = var.region
  target_key_id = aws_kms_key.flow_logs.key_id
}
