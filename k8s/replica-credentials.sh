#!/usr/bin/env bash
# Give the GKE replica read access to the primary's S3 archive.
#
# Creates an access key for the read-only IAM user from infra/30-data/aws and
# stores it, with the bucket's region, in the cnpg-db/aws-s3-reader Secret on
# GKE. The key goes straight from the AWS API into the Kubernetes API: it is
# never written to disk, never in git, never in OpenTofu state. Running it
# again rotates the key: the new one is stored first, then every other key of
# the user is deleted.
#
# Usage, after `tofu apply` in infra/30-data/aws and `make bootstrap CLOUD=gcp`:
#   k8s/replica-credentials.sh <gke-kube-context>
set -euo pipefail

usage() {
  echo "usage: $0 <gke-kube-context>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
context=$1
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=k8s/lib.sh
source k8s/lib.sh

require_tools tofu kubectl aws
check_cluster_context gcp

data_out() { tofu -chdir=infra/30-data/aws output -raw "$1"; }
user=$(data_out wal_reader_user)
region=$(data_out wal_bucket_region)

# IAM allows 2 keys per user; this script keeps it at 1.
existing=$(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text)
if [[ $(wc -w <<<"$existing") -ge 2 ]]; then
  echo "$user already has 2 access keys ($existing); delete one first" >&2
  exit 1
fi

echo "==> Creating an access key for $user"
read -r key_id key_secret < <(aws iam create-access-key --user-name "$user" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
[[ -n $key_id && -n $key_secret ]] || { echo "aws iam create-access-key returned no key" >&2; exit 1; }

echo "==> Storing it in cnpg-db/aws-s3-reader on $context"
kc create namespace cnpg-db --dry-run=client -o yaml | kc apply -f -
# Process substitution: the values pass through a pipe, not a file or argv.
# Server-side apply: a client-side apply would also copy the key into the
# Secret's last-applied-configuration annotation.
kc --namespace cnpg-db create secret generic aws-s3-reader \
  --from-env-file=<(printf 'ACCESS_KEY_ID=%s\nACCESS_SECRET_KEY=%s\nREGION=%s\n' "$key_id" "$key_secret" "$region") \
  --dry-run=client -o yaml | kc apply --server-side --field-manager=replica-credentials -f -
unset key_secret

for old in $existing; do
  echo "==> Deleting the previous key $old"
  aws iam delete-access-key --user-name "$user" --access-key-id "$old"
done

echo
echo "Done. $user has one key ($key_id), stored only in the cluster."
