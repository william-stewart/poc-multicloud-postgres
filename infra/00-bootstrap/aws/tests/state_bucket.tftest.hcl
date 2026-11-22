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

run "state_bucket_uses_the_state_key" {
  # plan, not apply: prevent_destroy would stop the test from cleaning up.
  # The override makes the key ARN known at plan time.
  command = plan

  override_resource {
    target = aws_kms_key.state
    values = { arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111" }
  }

  assert {
    condition = (
      one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).kms_master_key_id == "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111" &&
      one(aws_s3_bucket_server_side_encryption_configuration.state.rule).bucket_key_enabled
    )
    error_message = "State must be encrypted with the state key, with S3 bucket keys on."
  }

  assert {
    condition = (
      output.backend_config.bucket == "poc-mcpg-tfstate-123456789012-us-east-1" &&
      output.backend_config.region == "us-east-1" &&
      output.backend_config.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111" &&
      output.backend_config.use_lockfile
    )
    error_message = "backend_config must describe the bucket, region and key the AWS stacks' backends use."
  }
}

run "old_state_versions_expire" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket_lifecycle_configuration.state.rule[0].status == "Enabled" &&
      aws_s3_bucket_lifecycle_configuration.state.rule[0].noncurrent_version_expiration[0].noncurrent_days == 90
    )
    error_message = "Superseded state versions must expire after the retention period."
  }

  assert {
    condition     = strcontains(aws_kms_key.state.policy, "arn:aws:iam::123456789012:root")
    error_message = "The state key must be administered by this account."
  }
}

# These resources hold the state of every other AWS stack. Their names must
# never change, or OpenTofu would plan to replace them.
run "names_are_stable" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket.state.bucket == "poc-mcpg-tfstate-123456789012-us-east-1" &&
      aws_kms_alias.state.name == "alias/poc-mcpg-tfstate"
    )
    error_message = "State bucket or key alias name changed; that would replace live resources."
  }
}
