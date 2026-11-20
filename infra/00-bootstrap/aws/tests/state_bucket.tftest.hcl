mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }
}

run "state_bucket_is_private_and_encrypted" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "The state bucket must block every form of public access."
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.state.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled on the state bucket."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "State must be encrypted with KMS."
  }

  assert {
    condition     = aws_kms_key.state.enable_key_rotation
    error_message = "The state KMS key must rotate."
  }

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State versioning must be on so a bad apply can be rolled back."
  }

  assert {
    condition     = aws_s3_bucket.state.bucket == "poc-mcpg-tfstate-123456789012-us-east-1"
    error_message = "Unexpected state bucket name."
  }
}

run "bucket_policy_requires_tls" {
  command = plan

  assert {
    condition = (
      strcontains(aws_s3_bucket_policy.state.policy, "aws:SecureTransport") &&
      strcontains(aws_s3_bucket_policy.state.policy, "s3:TlsVersion")
    )
    error_message = "The bucket policy must deny non-TLS and pre-TLS-1.2 requests."
  }
}

run "rejects_invalid_prefix" {
  command = plan

  variables {
    name_prefix = "Bad_Prefix"
  }

  expect_failures = [var.name_prefix]
}
