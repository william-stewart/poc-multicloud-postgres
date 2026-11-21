#!/usr/bin/env bash
# Store the outputs of infra/30-data/<cloud> in the flux-system/data-vars
# ConfigMap, which the data Kustomization substitutes from. Until it exists,
# Flux applies nothing in k8s/data/<cloud>, so the database never starts with
# an empty bucket name or role.
#
# Usage, after `tofu apply` in infra/30-data/aws and `make bootstrap`:
#   k8s/data-vars.sh <aws|gcp> <kube-context>
set -euo pipefail

usage() {
  echo "usage: $0 <aws|gcp> <kube-context>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
cloud=$1
context=$2
[[ $cloud == aws || $cloud == gcp ]] || usage
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=k8s/lib.sh
source k8s/lib.sh

require_tools tofu kubectl
check_cluster_context "$cloud"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
vars="$workdir/data-vars.env"

case $cloud in
  aws)
    {
      echo "WAL_BUCKET=$(tofu -chdir=infra/30-data/aws output -raw wal_bucket)"
      echo "WAL_WRITER_ROLE_ARN=$(tofu -chdir=infra/30-data/aws output -raw wal_writer_role_arn)"
    } >"$vars"
    ;;
  gcp)
    echo "The GCP data layer (the replica) comes in the next phase." >&2
    exit 1
    ;;
esac

check_vars_match "k8s/clusters/$cloud/data-vars.example.env" "$vars"
apply_flux_configmap data-vars "$vars"

cat <<EOF

Flux applies k8s/data/$cloud on its next reconcile. To apply it now and watch:
  flux --context $context reconcile kustomization data --with-source
  kubectl --context $context -n cnpg-db get cluster,backup -w
EOF
