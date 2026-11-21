#!/usr/bin/env bash
# Give both clusters the same credentials for the app database owner.
#
# CloudNativePG's distributed topology needs identical role definitions,
# secrets included, on every member: after a switchover or failover the
# promoted cluster must accept the same password the applications already use.
# This script stores, on EKS and on GKE:
#   - cnpg-db/app-owner: the owner's username and password, which pg-primary
#     (initdb) and pg-replica (recovery) bootstrap with;
#   - app/postgres: what clients in the app namespace connect with, pointing
#     at the local cluster's -rw Service.
#
# The password is generated once and reused on later runs; it goes from
# memory straight into the Kubernetes API: no file, no git, no OpenTofu state.
# Run it before `make data-vars`, while both clusters are up, so the GKE side
# already holds the credentials if AWS is lost.
#
# Usage, after `make bootstrap` on both clusters:
#   k8s/app-credentials.sh <eks-kube-context> <gke-kube-context>
set -euo pipefail

usage() {
  echo "usage: $0 <eks-kube-context> <gke-kube-context>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
eks=$1
gke=$2
cd "$(git rev-parse --show-toplevel)"
context=$eks
# shellcheck source=k8s/lib.sh
source k8s/lib.sh

require_tools tofu kubectl openssl
context=$eks check_cluster_context aws
context=$gke check_cluster_context gcp

owner=app
database=app

# The current password on one cluster, or nothing if it has none yet. Any
# other error (an unreachable cluster) stops the script, so it never mistakes
# one for "no password" and generates a second one.
current_password() {
  local encoded
  encoded=$(kubectl --context "$1" --namespace cnpg-db get secret app-owner \
    --ignore-not-found -o jsonpath='{.data.password}')
  if [[ -n $encoded ]]; then
    base64 --decode <<<"$encoded"
  fi
}

eks_password=$(current_password "$eks")
gke_password=$(current_password "$gke")
if [[ -n $eks_password && -n $gke_password && $eks_password != "$gke_password" ]]; then
  echo "cnpg-db/app-owner differs between $eks and $gke; fix it by hand before running this" >&2
  exit 1
fi
password=${eks_password:-$gke_password}
if [[ -z $password ]]; then
  echo "==> Generating a new password for $owner"
  # URL-safe, so it can go into a connection URI unescaped.
  password=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
fi
unset eks_password gke_password

# Server-side apply: a client-side apply would also copy the password into the
# Secret's last-applied-configuration annotation.
store() {
  local ctx=$1 host=$2
  echo "==> $ctx: cnpg-db/app-owner and app/postgres (host $host)"
  for ns in cnpg-db app; do
    kubectl --context "$ctx" create namespace "$ns" --dry-run=client -o yaml |
      kubectl --context "$ctx" apply -f -
  done
  # Process substitution: the values pass through a pipe, not a file or argv.
  kubectl --context "$ctx" --namespace cnpg-db create secret generic app-owner \
    --type=kubernetes.io/basic-auth \
    --from-env-file=<(printf 'username=%s\npassword=%s\n' "$owner" "$password") \
    --dry-run=client -o yaml |
    kubectl --context "$ctx" apply --server-side --field-manager=app-credentials -f -
  kubectl --context "$ctx" --namespace app create secret generic postgres \
    --from-env-file=<(printf 'username=%s\npassword=%s\ndbname=%s\nhost=%s\nport=5432\n' \
      "$owner" "$password" "$database" "$host") \
    --dry-run=client -o yaml |
    kubectl --context "$ctx" apply --server-side --field-manager=app-credentials -f -
}

store "$eks" pg-primary-rw.cnpg-db.svc
store "$gke" pg-replica-rw.cnpg-db.svc
unset password

echo
echo "Done. Both clusters hold the same credentials for $owner."
