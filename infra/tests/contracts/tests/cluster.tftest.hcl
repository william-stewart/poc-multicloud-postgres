# Contract: infra/modules/cluster/contract.json
#
# Every implementation must return:
#   cluster_name            the `name` input
#   cluster_endpoint        an https:// URL (EKS returns one; GKE returns a bare
#                           IP, which the module must turn into a URL)
#   cluster_ca_certificate  non-empty base64
#   oidc_issuer_url         an https:// URL
#   kubeconfig_command      a command that mentions the cluster name
#
# Every provider is mocked, including time and null, which the EKS module
# uses, so nothing real runs during apply.
#
# Limitation: on GKE the CA certificate lives inside the master_auth block,
# and mocks can't set values inside blocks. So the gcp run checks that the
# output is a non-empty string taken from master_auth; the base64 format is
# only checked on AWS, where the mock can supply a realistic value.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:role/admin" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }

  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::123456789012:role/admin" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }

  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }

  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/eks/contract/cluster" }
  }

  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", arn = "arn:aws:ec2:us-east-1:123456789012:launch-template/lt-0123456789abcdef0" }
  }

  mock_resource "aws_security_group" {
    defaults = { id = "sg-0123456789abcdef0", arn = "arn:aws:ec2:us-east-1:123456789012:security-group/sg-0123456789abcdef0" }
  }

  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:us-east-1:123456789012:cluster/contract"
      endpoint              = "https://ABCDEF.gr7.us-east-1.eks.amazonaws.com"
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/ABCDEF" }] }]
      certificate_authority = [{ data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t" }]
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/ABCDEF" }
  }
}

mock_provider "tls" {}

mock_provider "time" {}
mock_provider "null" {}
mock_provider "cloudinit" {}

mock_provider "google" {
  mock_data "google_container_engine_versions" {
    defaults = { valid_master_versions = ["1.36.5-gke.1100000"] }
  }

  mock_resource "google_service_account" {
    defaults = { email = "contract-gke-nodes@poc-contract-test.iam.gserviceaccount.com" }
  }

  mock_resource "google_container_cluster" {
    defaults = { endpoint = "203.0.113.30" }
  }
}

run "aws" {
  command = apply

  module {
    source = "../../modules/cluster/aws"
  }

  variables {
    name               = "contract"
    kubernetes_version = "1.36"
    node_count         = 2
    machine_type       = "m6i.large"
    api_allowed_cidrs  = ["203.0.113.7/32"]
    labels             = { project = "contract" }
    region             = "us-east-1"
    vpc_id             = "vpc-0123456789abcdef0"
    subnet_ids         = ["subnet-a", "subnet-b", "subnet-c"]
  }

  assert {
    condition     = output.cluster_name == "contract"
    error_message = "cluster_name must equal the name input."
  }

  assert {
    condition     = startswith(output.cluster_endpoint, "https://") && length(output.cluster_endpoint) > length("https://")
    error_message = "cluster_endpoint must be an https:// URL."
  }

  assert {
    condition     = length(output.cluster_ca_certificate) > 0 && can(base64decode(output.cluster_ca_certificate))
    error_message = "cluster_ca_certificate must be non-empty base64."
  }

  assert {
    condition     = startswith(output.oidc_issuer_url, "https://")
    error_message = "oidc_issuer_url must be an https:// URL."
  }

  assert {
    condition     = strcontains(output.kubeconfig_command, "contract")
    error_message = "kubeconfig_command must name the cluster."
  }
}

run "gcp" {
  command = apply

  module {
    source = "../../modules/cluster/gcp"
  }

  variables {
    name                = "contract"
    kubernetes_version  = "1.36"
    node_count          = 2
    machine_type        = "e2-standard-4"
    api_allowed_cidrs   = ["203.0.113.7/32"]
    labels              = { project = "contract" }
    project_id          = "poc-contract-test"
    zone                = "us-central1-a"
    network_id          = "projects/poc-contract-test/global/networks/contract"
    subnet_id           = "projects/poc-contract-test/regions/us-central1/subnetworks/contract-nodes"
    pods_range_name     = "contract-pods"
    services_range_name = "contract-services"
    secrets_kms_key_id  = "projects/poc-contract-test/locations/us-central1/keyRings/contract-gke/cryptoKeys/contract-gke-secrets"
  }

  assert {
    condition     = output.cluster_name == "contract"
    error_message = "cluster_name must equal the name input."
  }

  assert {
    condition     = startswith(output.cluster_endpoint, "https://") && length(output.cluster_endpoint) > length("https://")
    error_message = "cluster_endpoint must be an https:// URL."
  }

  assert {
    condition     = length(output.cluster_ca_certificate) > 0 && output.cluster_ca_certificate == google_container_cluster.this.master_auth[0].cluster_ca_certificate
    error_message = "cluster_ca_certificate must be the cluster's CA from master_auth."
  }

  assert {
    condition     = startswith(output.oidc_issuer_url, "https://")
    error_message = "oidc_issuer_url must be an https:// URL."
  }

  assert {
    condition     = strcontains(output.kubeconfig_command, "contract")
    error_message = "kubeconfig_command must name the cluster."
  }
}
