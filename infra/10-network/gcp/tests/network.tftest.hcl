mock_provider "google" {}

variables {
  project_id = "poc-test-project"
}

run "uses_shared_settings" {
  command = plan

  assert {
    condition     = module.settings.cidrs.gcp_nodes == "10.20.0.0/20"
    error_message = "The node range must come from the settings module."
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
