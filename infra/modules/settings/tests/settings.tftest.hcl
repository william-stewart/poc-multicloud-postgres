run "default_address_plan_is_valid" {
  command = plan

  assert {
    condition     = output.cidrs.aws_vpc == "10.10.0.0/16" && output.cidrs.gcp_nodes == "10.20.0.0/20"
    error_message = "The address plan changed; update the README and every dependent stack together."
  }

  assert {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", output.name_prefix))
    error_message = "name_prefix must be 3-16 characters: lowercase letters, digits and hyphens, starting with a letter."
  }

  assert {
    condition     = output.regions.aws == "us-east-1" && output.regions.gcp == "us-central1"
    error_message = "Unexpected regions."
  }

  assert {
    condition     = alltrue([for z in output.zones.aws : startswith(z, "use1-az")]) && !contains(output.zones.aws, "use1-az3")
    error_message = "AWS zones must be us-east-1 zone IDs, excluding use1-az3 (no EKS support)."
  }

  assert {
    condition     = can(regex("^1\\.[0-9]+$", output.kubernetes.version)) && output.kubernetes.node_count >= 2
    error_message = "kubernetes.version must be a minor version like 1.36, with at least 2 nodes per cluster."
  }

  assert {
    condition     = output.kubernetes.node_image.aws == "BOTTLEROCKET_x86_64" && output.kubernetes.node_image.gcp == "COS_CONTAINERD"
    error_message = "Nodes must run the hardened container OS on each cloud: Bottlerocket on EKS, COS on GKE."
  }

  assert {
    condition     = startswith(output.zones.gcp, output.regions.gcp)
    error_message = "The GKE zone must be in the GCP region."
  }

  assert {
    condition     = alltrue([for k, v in output.labels : can(regex("^[a-z][a-z0-9_-]{0,62}$", k)) && can(regex("^[a-z0-9_-]{0,63}$", v))])
    error_message = "Labels must be valid GCP labels (lowercase), which also makes them valid AWS tags."
  }
}

run "rejects_overlapping_ranges" {
  command = plan

  variables {
    cidrs = {
      aws_vpc  = "10.10.0.0/16"
      gke_pods = "10.10.128.0/17"
    }
  }

  expect_failures = [var.cidrs]
}

run "rejects_ranges_outside_ten_slash_eight" {
  command = plan

  variables {
    cidrs = {
      aws_vpc = "192.168.0.0/16"
    }
  }

  expect_failures = [var.cidrs]
}

run "rejects_host_bits" {
  command = plan

  variables {
    cidrs = {
      aws_vpc = "10.10.0.1/16"
    }
  }

  expect_failures = [var.cidrs]
}
