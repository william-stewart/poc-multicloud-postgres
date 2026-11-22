output "cluster_name" {
  description = "EKS cluster name."
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API URL. k8s/platform needs its host for Cilium's k8sServiceHost."
  value       = module.cluster.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Adds the cluster to your kubeconfig."
  value       = module.cluster.kubeconfig_command
}

output "cilium_operator_role_arn" {
  description = "IRSA role for kube-system/cilium-operator."
  value       = module.cluster.cilium_operator_role_arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role for kube-system/ebs-csi-controller-sa."
  value       = module.cluster.ebs_csi_role_arn
}

output "oidc_issuer_url" {
  description = "OIDC issuer of the cluster's service account tokens. 30-data/gcp trusts it for Workload Identity Federation."
  value       = module.cluster.oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider, for IRSA roles in later stacks (30-data)."
  value       = module.cluster.oidc_provider_arn
}

output "region" {
  description = "Region of the cluster, for the AWS CLI calls in make bootstrap."
  value       = module.settings.regions.aws
}

output "node_group_name" {
  description = "The managed node group, created empty; make bootstrap scales it to node_count once Cilium is installed."
  value       = module.cluster.node_group_name
}

output "node_count" {
  description = "Nodes make bootstrap scales the node group to."
  value       = module.cluster.node_count
}
