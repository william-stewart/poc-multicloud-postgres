# --- Shared cluster interface (see ../contract.json) ---

output "cluster_name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "cluster_endpoint" {
  description = "HTTPS URL of the Kubernetes API."
  value       = "https://${google_container_cluster.this.endpoint}"
}

output "cluster_ca_certificate" {
  description = "Base64-encoded PEM CA certificate of the Kubernetes API."
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
}

output "oidc_issuer_url" {
  description = "OIDC issuer of the cluster's service account tokens."
  value       = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${var.zone}/clusters/${google_container_cluster.this.name}"
}

output "kubeconfig_command" {
  description = "Command that adds this cluster to your kubeconfig."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone ${var.zone} --project ${var.project_id}"
}

# --- GCP only ---

output "node_service_account" {
  description = "Email of the nodes' service account."
  value       = google_service_account.nodes.email
}

output "workload_identity_pool" {
  description = "Workload Identity pool, for binding Kubernetes service accounts to Google service accounts."
  value       = "${var.project_id}.svc.id.goog"
}
