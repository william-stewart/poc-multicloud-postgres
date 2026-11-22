mock_provider "aws" {
  # Mocks return random strings, but IAM policies must be valid JSON.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # Mocks return random strings, but these attributes are validated as ARNs.
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }

  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-log/mock" }
  }

  override_data {
    target = data.aws_availability_zones.available
    # Sorted by name, as AWS returns them; the account maps IDs to names freely.
    values = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az4", "use1-az1", "use1-az2"]
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }
}

variables {
  name     = "test"
  region   = "us-east-1"
  cidr     = "10.10.0.0/16"
  labels   = { project = "test" }
  zone_ids = ["use1-az1", "use1-az2", "use1-az4"]
}

run "subnet_layout" {
  command = plan

  assert {
    condition     = local.azs == ["us-east-1b", "us-east-1c", "us-east-1a"]
    error_message = "AZ names must follow the order of zone_ids."
  }

  assert {
    condition     = local.private_subnets == ["10.10.0.0/19", "10.10.32.0/19", "10.10.64.0/19"]
    error_message = "Private subnets must be one /19 per AZ, from the start of the VPC range."
  }

  assert {
    condition     = local.public_subnets == ["10.10.96.0/24", "10.10.97.0/24", "10.10.98.0/24"]
    error_message = "Public subnets must be one /24 per AZ, after the private ranges."
  }

  assert {
    condition = alltrue([
      for p in local.public_subnets : !anytrue([for q in local.private_subnets : cidrcontains(q, cidrhost(p, 0))])
    ])
    error_message = "Public and private subnets must not overlap."
  }
}

# Checked on the subnets the VPC module actually creates, not on the locals
# passed to it: network-lookup/aws finds them by these tags.
run "subnets_tagged_for_lookup" {
  command = plan

  assert {
    condition     = length(module.vpc.private_subnet_objects) == 3 && alltrue([for s in module.vpc.private_subnet_objects : s.tags.tier == "private"])
    error_message = "Every private subnet must carry tier = private, which network-lookup/aws filters on."
  }

  assert {
    condition     = length(module.vpc.public_subnet_objects) == 3 && alltrue([for s in module.vpc.public_subnet_objects : s.tags.tier == "public"])
    error_message = "Every public subnet must carry tier = public."
  }

  assert {
    condition = (
      alltrue([for s in module.vpc.private_subnet_objects : s.tags["kubernetes.io/role/internal-elb"] == "1"]) &&
      alltrue([for s in module.vpc.public_subnet_objects : s.tags["kubernetes.io/role/elb"] == "1"])
    )
    error_message = "Subnets must carry the load balancer role tags."
  }

  assert {
    condition     = module.vpc.name == "test"
    error_message = "The VPC's Name tag (the module's name) must equal name; network-lookup/aws finds the VPC by it."
  }
}

run "subnets_are_created_as_planned" {
  command = plan

  assert {
    condition     = [for s in module.vpc.private_subnet_objects : s.cidr_block] == local.private_subnets && [for s in module.vpc.public_subnet_objects : s.cidr_block] == local.public_subnets
    error_message = "The VPC module must create the planned CIDRs."
  }

  assert {
    condition     = [for s in module.vpc.private_subnet_objects : s.availability_zone] == ["us-east-1b", "us-east-1c", "us-east-1a"]
    error_message = "Subnet i must be in zone_ids[i]."
  }

  assert {
    condition     = alltrue([for s in concat(module.vpc.private_subnet_objects, module.vpc.public_subnet_objects) : s.map_public_ip_on_launch != true])
    error_message = "No subnet may hand out public IPs automatically."
  }

  assert {
    condition     = length(module.vpc.natgw_ids) == 1
    error_message = "The PoC uses exactly one NAT gateway."
  }
}

run "default_security_group_denies_all" {
  command = plan

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "The default security group must have no rules."
  }
}

run "s3_traffic_skips_nat" {
  command = plan

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway"
    error_message = "S3 must be reached through a gateway endpoint."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-1.s3"
    error_message = "The S3 endpoint must be in the VPC's region."
  }
}

run "s3_endpoint_serves_private_subnets" {
  # apply (against mocks) so route table IDs are known and can be compared.
  command = apply

  # Mocks give every resource of a type the same random ID, which would make
  # private and public route tables indistinguishable. Pin distinct IDs.
  override_resource {
    target = module.vpc.aws_route_table.private
    values = { id = "rtb-private" }
  }

  override_resource {
    target = module.vpc.aws_route_table.public
    values = { id = "rtb-public" }
  }

  assert {
    condition     = length(aws_vpc_endpoint.s3.route_table_ids) > 0 && aws_vpc_endpoint.s3.route_table_ids == toset(["rtb-private"])
    error_message = "The S3 gateway endpoint must be on the private route tables, or WAL archiving goes through NAT (and the writer's VPCE condition denies it)."
  }
}

run "flow_logs_encrypted" {
  command = plan

  assert {
    condition     = aws_kms_alias.flow_logs.name == "alias/test-vpc-flow-logs"
    error_message = "Unexpected flow log key alias."
  }

  assert {
    condition     = strcontains(aws_kms_key.flow_logs.policy, "\"logs.us-east-1.amazonaws.com\"")
    error_message = "Only CloudWatch Logs in this region may use the flow log key."
  }

  assert {
    condition     = aws_kms_key.flow_logs.enable_key_rotation
    error_message = "The flow log key must rotate."
  }

  assert {
    condition     = strcontains(aws_kms_key.flow_logs.policy, "log-group:/aws/vpc-flow-log/*")
    error_message = "CloudWatch Logs may use the key only for VPC flow log groups."
  }
}

run "rejects_single_az" {
  command = plan

  variables {
    zone_ids = ["use1-az1"]
  }

  expect_failures = [var.zone_ids]
}

run "rejects_duplicate_zones" {
  command = plan

  variables {
    zone_ids = ["use1-az1", "use1-az1"]
  }

  expect_failures = [var.zone_ids]
}
