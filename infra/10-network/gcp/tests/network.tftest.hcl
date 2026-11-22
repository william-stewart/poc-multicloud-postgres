mock_provider "google" {}

variables {
  project_id = "poc-test-project"
}

run "uses_shared_settings" {
  command = plan

  # Later stacks (network-lookup/gcp) find the network and subnet by name.
  assert {
    condition     = module.network.network_name == "poc-mcpg" && module.network.subnet_name == "poc-mcpg-nodes"
    error_message = "The network and node subnet must be named after the settings prefix."
  }

  assert {
    condition     = module.network.pods_range_name == "poc-mcpg-pods" && module.network.services_range_name == "poc-mcpg-services"
    error_message = "Secondary range names must follow the settings name prefix."
  }
}

run "rejects_invalid_project_id" {
  command = plan

  variables {
    project_id = "Not_A_Project"
  }

  expect_failures = [var.project_id]
}
