#!/usr/bin/env bash
# Shared helpers for the k8s/ scripts. Source it after
# setting $context (the kube-context to act on) and cd-ing to the repo root.

# shellcheck disable=SC2154  # $context is set by the sourcing script.
: "${context:?set context before sourcing k8s/lib.sh}"

kc() { kubectl --context "$context" "$@"; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
  done
}

# Refuse to touch a cluster other than the one infra/20-clusters/<cloud> built.
check_cluster_context() {
  local cloud=$1 endpoint server
  endpoint=$(tofu -chdir="infra/20-clusters/$cloud" output -raw cluster_endpoint)
  server=$(kubectl config view --minify --context "$context" -o jsonpath='{.clusters[0].cluster.server}')
  if [[ ${server%/} != "${endpoint%/}" ]]; then
    echo "context $context points at $server, but infra/20-clusters/$cloud built $endpoint" >&2
    exit 1
  fi
}

# The collected variables must be exactly the ones the manifests expect.
check_vars_match() {
  local example=$1 vars=$2
  if ! diff <(grep -Ev '^(#|$)' "$example" | cut -d= -f1 | sort) <(cut -d= -f1 "$vars" | sort) >/dev/null; then
    echo "collected variables don't match $example" >&2
    exit 1
  fi
}

# Create or update a ConfigMap in flux-system from an env file.
apply_flux_configmap() {
  local name=$1 vars=$2
  # Create the namespace only if it's missing: Flux's own install creates it
  # without the annotation client-side apply expects, and applying over that
  # prints a warning.
  kc get namespace flux-system >/dev/null 2>&1 || kc create namespace flux-system
  kc --namespace flux-system create configmap "$name" --from-env-file="$vars" \
    --dry-run=client -o yaml | kc apply -f -
}
