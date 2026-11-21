# --- Shared cluster interface (see ../contract.json) ---

output "cluster_name" {
  description = "Cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "HTTPS URL of the Kubernetes API."
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded PEM CA certificate of the Kubernetes API."
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_issuer_url" {
  description = "OIDC issuer of the cluster's service account tokens."
  value       = module.eks.cluster_oidc_issuer_url
}

output "kubeconfig_command" {
  description = "Command that adds this cluster to your kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}

# --- AWS only ---

output "oidc_provider_arn" {
  description = "IAM OIDC provider for IRSA."
  value       = module.eks.oidc_provider_arn
}

output "cilium_operator_role_arn" {
  description = "IRSA role for kube-system/cilium-operator (annotate its service account with this)."
  value       = aws_iam_role.irsa["cilium_operator"].arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role for kube-system/ebs-csi-controller-sa."
  value       = aws_iam_role.irsa["ebs_csi"].arn
}

output "node_security_group_id" {
  description = "Security group shared by the nodes (and, in Cilium ENI mode, by pod ENIs)."
  value       = module.eks.node_security_group_id
}
