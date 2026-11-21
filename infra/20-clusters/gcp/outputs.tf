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

output "workload_identity_pool" {
  description = "Workload Identity pool of the cluster."
  value       = module.cluster.workload_identity_pool
}
