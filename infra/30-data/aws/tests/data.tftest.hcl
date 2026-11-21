mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_eks_cluster" {
    defaults = { identity = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/ABCDEF" }] }] }
  }

  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/ABCDEF" }
  }

  mock_data "aws_vpc_endpoint" {
    defaults = { id = "vpce-0123456789abcdef0" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  # network-lookup/aws
  mock_data "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }

  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"] }
  }

  mock_data "aws_nat_gateways" {
    defaults = { ids = ["nat-0123456789abcdef0"] }
  }

  mock_data "aws_nat_gateway" {
    defaults = { public_ip = "203.0.113.10" }
  }

  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::poc-mcpg-wal-123456789012-us-east-1" }
  }

  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/container.googleapis.com/v1/projects/poc-test-project/locations/us-central1-a/clusters/poc-mcpg" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/poc-mcpg-wal-writer" }
  }
}

variables {
  replica_egress_ips  = ["203.0.113.20"]
  gke_oidc_issuer_url = "https://container.googleapis.com/v1/projects/poc-test-project/locations/us-central1-a/clusters/poc-mcpg"
}

run "bucket_is_private_and_encrypted" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.wal.block_public_acls,
      aws_s3_bucket_public_access_block.wal.block_public_policy,
      aws_s3_bucket_public_access_block.wal.ignore_public_acls,
      aws_s3_bucket_public_access_block.wal.restrict_public_buckets,
    ])
    error_message = "The WAL bucket must block every form of public access."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.wal.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "The WAL archive must be encrypted with KMS."
  }

  assert {
    condition     = aws_kms_key.wal.enable_key_rotation
    error_message = "The WAL key must rotate."
  }

  assert {
    condition     = aws_s3_bucket_versioning.wal.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning must be on, so a bad delete can be recovered."
  }

  assert {
    condition     = strcontains(aws_s3_bucket_policy.wal.policy, "aws:SecureTransport") && strcontains(aws_s3_bucket_policy.wal.policy, "s3:TlsVersion")
    error_message = "The bucket policy must deny non-TLS and pre-TLS-1.2 requests."
  }
}

run "writer_is_only_the_primary_cluster" {
  command = plan

  assert {
    condition     = one([for c in data.aws_iam_policy_document.writer_trust.statement[0].condition : c.values if endswith(c.variable, ":sub")]) == tolist(["system:serviceaccount:cnpg-db:pg-primary"])
    error_message = "Only the pg-primary service account in cnpg-db may assume the writer role."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.writer.statement :
      alltrue([for r in s.resources : endswith(r, "/pg-primary/*")]) if s.sid == "ReadWriteOwnPrefix"
    ])
    error_message = "The writer may only write under the primary's prefix."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.writer.statement :
      anytrue([for c in s.condition : c.variable == "aws:SourceVpce" && contains(c.values, "vpce-0123456789abcdef0")])
      if anytrue([for a in s.actions : startswith(a, "s3:")])
    ])
    error_message = "Every S3 permission of the writer must require the VPC's gateway endpoint."
  }
}

run "reader_is_only_the_replica_cluster_without_a_key" {
  command = plan

  assert {
    condition     = one([for c in data.aws_iam_policy_document.reader_trust.statement[0].condition : c.values if c.variable == "container.googleapis.com/v1/projects/poc-test-project/locations/us-central1-a/clusters/poc-mcpg:sub"]) == tolist(["system:serviceaccount:cnpg-db:pg-replica"])
    error_message = "Only the pg-replica service account on the GKE cluster may assume the reader role."
  }

  assert {
    condition     = one([for c in data.aws_iam_policy_document.reader_trust.statement[0].condition : c.values if endswith(c.variable, ":aud")]) == tolist(["sts.amazonaws.com"])
    error_message = "The reader role must only accept tokens minted for AWS STS."
  }

  assert {
    condition     = aws_iam_openid_connect_provider.gke.url == "https://container.googleapis.com/v1/projects/poc-test-project/locations/us-central1-a/clusters/poc-mcpg"
    error_message = "The OIDC provider must trust exactly the GKE cluster's issuer."
  }
}

run "reader_is_read_only_from_the_gcp_nat" {
  command = plan

  assert {
    condition     = sort(flatten([for s in data.aws_iam_policy_document.reader.statement : tolist(s.actions)])) == tolist(["kms:Decrypt", "s3:GetObject", "s3:ListBucket"])
    error_message = "The reader may only list, read and decrypt."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.reader.statement :
      anytrue([for c in s.condition : c.variable == "aws:SourceIp" && c.values == tolist(["203.0.113.20/32"])])
      if anytrue([for a in s.actions : startswith(a, "s3:")])
    ])
    error_message = "Every S3 permission of the reader must be limited to the GCP NAT IP."
  }
}

run "no_wildcard_actions" {
  command = plan

  assert {
    condition = alltrue([
      for s in concat(data.aws_iam_policy_document.writer.statement, data.aws_iam_policy_document.reader.statement) :
      alltrue([for a in s.actions : !strcontains(a, "*")])
    ])
    error_message = "IAM statements must name each action; no wildcards."
  }
}

run "rejects_cidr_ranges_for_the_replica" {
  command = plan

  variables {
    replica_egress_ips = ["0.0.0.0/0"]
  }

  expect_failures = [var.replica_egress_ips]
}

run "rejects_a_non_gke_issuer" {
  command = plan

  variables {
    gke_oidc_issuer_url = "https://token.actions.githubusercontent.com"
  }

  expect_failures = [var.gke_oidc_issuer_url]
}

run "rejects_empty_replica_ip_list" {
  command = plan

  variables {
    replica_egress_ips = []
  }

  expect_failures = [var.replica_egress_ips]
}
