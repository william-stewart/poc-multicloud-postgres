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

output "oidc_provider_arn" {
  description = "IAM OIDC provider, for IRSA roles in later stacks (30-data)."
  value       = module.cluster.oidc_provider_arn
}
