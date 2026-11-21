output "cluster_name" {
  description = "GKE cluster name."
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API URL."
  value       = module.cluster.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Adds the cluster to your kubeconfig."
  value       = module.cluster.kubeconfig_command
}

output "pods_cidr" {
  description = "Pod range. k8s/platform needs it for Cilium's ipv4NativeRoutingCIDR."
  value       = module.settings.cidrs.gke_pods
}

output "oidc_issuer_url" {
  description = "OIDC issuer of the cluster's service account tokens. 30-data/aws trusts it, so pg-replica can read S3 without a key."
  value       = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${module.settings.zones.gcp}/clusters/${module.cluster.cluster_name}"
}

output "workload_identity_pool" {
  description = "Workload Identity pool of the cluster."
  value       = module.cluster.workload_identity_pool
}
