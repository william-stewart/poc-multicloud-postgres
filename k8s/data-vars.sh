#!/usr/bin/env bash
# Store the outputs of infra/30-data/aws and infra/30-data/gcp in the
# flux-system/data-vars ConfigMap, which the data and policies Kustomizations
# substitute from. Until it exists, Flux applies neither, so the database
# never starts with an empty bucket name or role. On EKS it also stores
# pg-primary's GCS credential configuration (no key in it) in the
# cnpg-db/gcs-reader Secret.
#
# Usage, after `tofu apply` in both infra/30-data stacks, `make bootstrap`
# and `make app-credentials`:
#   k8s/data-vars.sh <aws|gcp> <kube-context>
#
# It refuses to run until the database can start: the app owner credentials
# must be in the cluster, and on GCP the primary's first base backup must be
# in S3.
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

if ! kc --namespace cnpg-db get secret app-owner >/dev/null 2>&1; then
  echo "cnpg-db/app-owner is missing; run make app-credentials first" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
vars="$workdir/data-vars.env"

case $cloud in
  aws)
    {
      echo "WAL_BUCKET=$(tofu -chdir=infra/30-data/aws output -raw wal_bucket)"
      echo "WAL_WRITER_ROLE_ARN=$(tofu -chdir=infra/30-data/aws output -raw wal_writer_role_arn)"
      echo "WAL_BUCKET_REGION=$(tofu -chdir=infra/30-data/aws output -raw wal_bucket_region)"
      echo "GCS_WAL_BUCKET=$(tofu -chdir=infra/30-data/gcp output -raw wal_bucket)"
      echo "GCP_PROJECT_ID=$(tofu -chdir=infra/30-data/gcp output -raw project_id)"
    } >"$vars"
    # Not a secret (it names a token file and a provider), but the Barman
    # Cloud plugin only reads GCS credentials from a Secret.
    kc --namespace cnpg-db create secret generic gcs-reader \
      --from-file=credentials.json=<(tofu -chdir=infra/30-data/gcp output -raw eks_reader_credential_config) \
      --dry-run=client -o yaml | kc apply --server-side --field-manager=data-vars -f -
    ;;
  gcp)
    require_tools aws
    bucket=$(tofu -chdir=infra/30-data/aws output -raw wal_bucket)
    # The replica bootstraps from a base backup; without one it fails.
    if [[ -z $(aws s3api list-objects-v2 --bucket "$bucket" --prefix pg-primary/base/ \
      --max-items 1 --query 'Contents[].Key' --output text | grep -v '^None$' || true) ]]; then
      echo "no base backup under s3://$bucket/pg-primary/base/ yet; wait for the primary's first backup" >&2
      exit 1
    fi
    {
      echo "WAL_BUCKET=$bucket"
      echo "WAL_BUCKET_REGION=$(tofu -chdir=infra/30-data/aws output -raw wal_bucket_region)"
      echo "WAL_READER_ROLE_ARN=$(tofu -chdir=infra/30-data/aws output -raw wal_reader_role_arn)"
      echo "GCS_WAL_BUCKET=$(tofu -chdir=infra/30-data/gcp output -raw wal_bucket)"
      echo "GCS_WAL_WRITER_SA=$(tofu -chdir=infra/30-data/gcp output -raw wal_writer_service_account)"
    } >"$vars"
    ;;
esac

check_vars_match "k8s/clusters/$cloud/data-vars.example.env" "$vars"
apply_flux_configmap data-vars "$vars"

cat <<EOF

Flux applies k8s/data/$cloud on its next reconcile. To apply it now and watch:
  flux --context $context reconcile kustomization data --with-source
  kubectl --context $context -n cnpg-db get cluster -w
  kubectl --context $context -n cnpg-db get backup -w
EOF
