#!/usr/bin/env bash
# Bootstrap the Kubernetes layer on one cluster.
#
# Nothing can run before the CNI, and on EKS Flux can't resolve github.com
# before CoreDNS. So this script installs those first with the Helm CLI, from
# the same values files and versions Flux uses, then installs Flux. Flux takes
# over the existing releases and installs the rest of k8s/platform from git.
#
# Usage, from anywhere in the repo, after `tofu apply` in infra/20-clusters/<cloud>:
#   k8s/bootstrap.sh <aws|gcp> <kube-context> [deploy-key-file]
#
# deploy-key-file defaults to secrets/flux-deploy-key: the private half of a
# read-only GitHub deploy key (see README). It is stored in the cluster as the
# flux-system Secret and never committed.
set -euo pipefail

# Must match the HelmReleases in k8s/platform (make validate checks this).
CILIUM_VERSION="1.20.5"
COREDNS_VERSION="1.50.8"
REPO_URL="ssh://git@github.com/william-stewart/poc-multicloud-postgres"

usage() {
  echo "usage: $0 <aws|gcp> <kube-context> [deploy-key-file]" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
cloud=$1
context=$2
cd "$(git rev-parse --show-toplevel)"
deploy_key=${3:-secrets/flux-deploy-key}
[[ $cloud == aws || $cloud == gcp ]] || usage

for tool in tofu kubectl helm flux; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[[ -f $deploy_key ]] || { echo "deploy key not found: $deploy_key (see README)" >&2; exit 1; }

kc() { kubectl --context "$context" "$@"; }
out() { tofu -chdir="infra/20-clusters/$cloud" output -raw "$1"; }

# Refuse to touch a cluster other than the one this stack built.
endpoint=$(out cluster_endpoint)
server=$(kubectl config view --minify --context "$context" -o jsonpath='{.clusters[0].cluster.server}')
if [[ ${server%/} != "${endpoint%/}" ]]; then
  echo "context $context points at $server, but infra/20-clusters/$cloud built $endpoint" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
vars="$workdir/cluster-vars.env"

echo "==> Collecting cluster variables"
case $cloud in
  aws)
    # The cluster DNS IP is the 10th address of the service CIDR; the
    # kubernetes Service holds the 1st.
    kubernetes_ip=$(kc get service kubernetes --namespace default -o jsonpath='{.spec.clusterIP}')
    [[ $kubernetes_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.1$ ]] || { echo "unexpected kubernetes Service IP: $kubernetes_ip" >&2; exit 1; }
    {
      echo "EKS_API_HOST=${endpoint#https://}"
      echo "EKS_DNS_SERVICE_IP=${kubernetes_ip%.*}.10"
      echo "CILIUM_OPERATOR_ROLE_ARN=$(out cilium_operator_role_arn)"
    } >"$vars"
    ;;
  gcp)
    echo "GKE_PODS_CIDR=$(out pods_cidr)" >"$vars"
    ;;
esac

# The variables must be exactly the ones the manifests expect.
example="k8s/clusters/$cloud/cluster-vars.example.env"
if ! diff <(grep -Ev '^(#|$)' "$example" | cut -d= -f1 | sort) <(cut -d= -f1 "$vars" | sort) >/dev/null; then
  echo "collected variables don't match $example" >&2
  exit 1
fi

# The values files reference ${VARS}; export them for flux envsubst.
set -a
# shellcheck disable=SC1090
source "$vars"
set +a

render() { flux envsubst --strict <"$1" >"$2"; }

echo "==> flux-system/cluster-vars ConfigMap"
kc create namespace flux-system --dry-run=client -o yaml | kc apply -f -
kc --namespace flux-system create configmap cluster-vars --from-env-file="$vars" \
  --dry-run=client -o yaml | kc apply -f -

echo "==> Cilium $CILIUM_VERSION"
render k8s/platform/base/cilium/values.yaml "$workdir/cilium-base.yaml"
render "k8s/platform/$cloud/cilium-values.yaml" "$workdir/cilium-cloud.yaml"
helm upgrade --install cilium cilium --repo https://helm.cilium.io --version "$CILIUM_VERSION" \
  --kube-context "$context" --namespace kube-system \
  -f "$workdir/cilium-base.yaml" -f "$workdir/cilium-cloud.yaml" --wait --timeout 10m

echo "==> Waiting for nodes to become Ready"
kc wait --for=condition=Ready nodes --all --timeout=10m

if [[ $cloud == aws ]]; then
  echo "==> CoreDNS $COREDNS_VERSION"
  render k8s/platform/aws/coredns/values.yaml "$workdir/coredns.yaml"
  helm upgrade --install coredns coredns --repo https://coredns.github.io/helm --version "$COREDNS_VERSION" \
    --kube-context "$context" --namespace kube-system -f "$workdir/coredns.yaml" --wait --timeout 5m
fi

echo "==> Flux"
flux create secret git flux-system --context "$context" --namespace flux-system \
  --url="$REPO_URL" --private-key-file="$deploy_key"
kc apply --server-side -k k8s/flux
kc --namespace flux-system wait --for=condition=Available deployment --all --timeout=5m
kc apply --server-side -k "k8s/clusters/$cloud"

cat <<EOF

Flux now reconciles k8s/clusters/$cloud from main and takes over the releases
installed above. Watch it with:
  flux --context $context get kustomizations --watch
  flux --context $context get helmreleases -A
EOF
