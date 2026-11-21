#!/usr/bin/env bash
# List, and with --delete remove, the ENIs Cilium left behind in the EKS VPC.
#
# In ENI mode the Cilium operator creates ENIs, tags them
# io.cilium/cilium-managed=true, and garbage-collects unattached ones every
# 5 minutes. Once the cluster is destroyed nothing does that any more, and a
# leftover ENI blocks `tofu destroy` in infra/10-network/aws. Run this after
# destroying infra/20-clusters/aws and before destroying the network.
#
# Only ENIs that are in this project's VPC, carry Cilium's tag and are
# unattached (status available) are touched.
#
# Usage:
#   scripts/cilium-enis.sh            # list only
#   scripts/cilium-enis.sh --delete   # delete them
set -euo pipefail

delete=false
case ${1:-} in
  "") ;;
  --delete) delete=true ;;
  *) echo "usage: $0 [--delete]" >&2; exit 2 ;;
esac

cd "$(git rev-parse --show-toplevel)"
for tool in tofu aws; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

vpc=$(tofu -chdir=infra/10-network/aws output -raw network_id)
# Captured first, so an AWS error stops the script instead of looking like
# "nothing to clean up".
ids=$(aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$vpc" "Name=status,Values=available" \
  "Name=tag:io.cilium/cilium-managed,Values=true" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
read -r -a enis <<<"$ids"

if [[ ${#enis[@]} -eq 0 ]]; then
  echo "no leftover Cilium ENIs in $vpc"
  exit 0
fi

echo "leftover Cilium ENIs in $vpc: ${enis[*]}"
if ! $delete; then
  echo "run again with --delete (make cilium-enis DELETE=1) to remove them"
  exit 0
fi

for eni in "${enis[@]}"; do
  echo "==> deleting $eni"
  aws ec2 delete-network-interface --network-interface-id "$eni"
done
