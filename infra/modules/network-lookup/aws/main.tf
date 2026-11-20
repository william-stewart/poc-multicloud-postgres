# Finds the network built by modules/network/aws. It relies on two things
# that module guarantees: the VPC's Name tag equals `name`, and subnets carry
# a `tier` tag of "private" or "public".

data "aws_vpc" "this" {
  region = var.region

  filter {
    name   = "tag:Name"
    values = [var.name]
  }
}

data "aws_subnets" "private" {
  region = var.region

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }

  filter {
    name   = "tag:tier"
    values = ["private"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) >= 2
      error_message = "Expected private subnets in at least 2 AZs (EKS minimum). Has 10-network/aws been applied?"
    }
  }
}

data "aws_subnets" "public" {
  region = var.region

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }

  filter {
    name   = "tag:tier"
    values = ["public"]
  }
}

data "aws_nat_gateways" "this" {
  region = var.region
  vpc_id = data.aws_vpc.this.id

  filter {
    name   = "state"
    values = ["available"]
  }
}

data "aws_nat_gateway" "this" {
  for_each = toset(data.aws_nat_gateways.this.ids)

  region = var.region
  id     = each.value
}
