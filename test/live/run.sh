#!/usr/bin/env bash
# Disaster recovery drill on the live clusters: pg-primary on EKS and
# pg-replica on GKE, as deployed by docs/deploy.md. Only scenarios that end
# where they started, so it can run any number of times:
#
#   1. Replication: a row written on pg-primary reaches pg-replica through S3,
#      and pg-replica archives it again to its own GCS archive.
#   2. Kill the primary pod on EKS: the other instance takes writes, no
#      committed row is lost, and replication continues.
#   3. Lose pg-replica's pod on GKE: it comes back and resumes from S3.
#   4. Planned switchover to pg-replica and back, with promotion tokens: no row
#      lost, and replication runs in both directions (pg-primary reads GCS
#      through Workload Identity Federation while pg-replica is the primary).
#   5. Network policy: the flows Cilium dropped in cnpg-db during the run,
#      reported (not failed) so a missing allow rule shows up by name instead
#      of as a timeout.
#
# Role changes are made with kubectl patch while Flux's data layer is
# suspended on both clusters, not through commits: one command, nothing
# pushed. At the end the live spec matches git again and Flux is resumed. If a
# run fails while the roles are swapped, Flux stays suspended: resuming it
# would apply git's roles over a topology that has moved, so the script prints
# the state instead and leaves the decision to the admin.
#
# Measurements go to evidence/live/<UTC time>.md (commit it as the record of
# the run); diagnostics from a failed run go to test/live/results/ (ignored).
# Rows are written to the live_drill table in the app database and kept.
#
# Usage (make live-drill):
#   test/live/run.sh <eks-kube-context> <gke-kube-context>
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <eks-kube-context> <gke-kube-context>" >&2; exit 2; }
EKS=$1
GKE=$2
NS=cnpg-db
cd "$(git rev-parse --show-toplevel)"
context=$EKS
# shellcheck source=k8s/lib.sh
source k8s/lib.sh

log() { printf '\n==> %s\n' "$*"; }
now() { python3 -c 'import time; print(f"{time.time():.1f}")'; }
since() { python3 -c 'import sys, time; print(f"{time.time() - float(sys.argv[1]):.1f}")' "$1"; }

# Each Cluster lives on its own cloud.
context_of() {
  case $1 in
    pg-primary) echo "$EKS" ;;
    pg-replica) echo "$GKE" ;;
    *) echo "unknown cluster $1" >&2; return 1 ;;
  esac
}
k() { # cluster kubectl-args...
  local ctx
  ctx=$(context_of "$1")
  shift
  kubectl --context "$ctx" --namespace "$NS" "$@"
}

# --- Results -----------------------------------------------------------------

stamp=$(date -u +%Y%m%dT%H%M%SZ)
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
evidence=evidence/live/$stamp.md
diagnostics=test/live/results/$stamp
rows=$(mktemp)
failures=0
scenario=preflight
suspended=0

record() { # check result measurement
  printf '| %s | %s | %s | %s |\n' "$scenario" "$1" "$2" "${3:-}" >>"$rows"
  printf '    [%s] %s %s\n' "$2" "$1" "${3:+($3)}"
  if [[ $2 == FAIL ]]; then failures=$((failures + 1)); fi
}

wait_until() { # timeout command...
  local timeout=$1 start
  shift
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if (($(date +%s) - start > timeout)); then return 1; fi
    sleep 5
  done
}

# A check whose failure makes the rest of the run meaningless.
require() { # description timeout command...
  local description=$1 timeout=$2
  shift 2
  if ! wait_until "$timeout" "$@"; then
    record "$description" FAIL "not met within ${timeout}s"
    exit 1
  fi
}

begin_scenario() { # name
  scenario=$1
  log "$scenario"
}

server_version() { # kube-context
  kubectl --context "$1" version -o json 2>/dev/null |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null || echo unknown
}
node_count() { kubectl --context "$1" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '; }
chart_version() {
  sed -n 's/^ *version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "k8s/platform/base/$1/helmrelease.yaml" | head -1
}

# No kube contexts, account IDs or project IDs: the file is committed.
write_evidence() {
  local status=PASS
  if ((failures > 0)); then status=FAIL; fi
  mkdir -p "$(dirname "$evidence")"
  {
    echo "# Live drill $stamp"
    echo
    echo "- Result: **$status** ($failures failed checks)"
    echo "- Commit: $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- k8s test/live || echo ' (with uncommitted changes)')"
    echo "- EKS: Kubernetes $(server_version "$EKS"), $(node_count "$EKS") node(s)"
    echo "- GKE: Kubernetes $(server_version "$GKE"), $(node_count "$GKE") node(s)"
    echo "- Charts: cloudnative-pg $(chart_version cloudnative-pg), plugin-barman-cloud $(chart_version plugin-barman-cloud), cilium $(chart_version cilium)"
    echo "- PostgreSQL: $(sed -n 's/^ *value: *//p' k8s/data/components/postgres-image/kustomization.yaml)"
    echo
    echo "| Scenario | Check | Result | Measurement |"
    echo "| --- | --- | --- | --- |"
    cat "$rows"
    echo
    echo "Run on the live clusters, with their cloud identities, network policies and"
    echo "object stores. Role changes were made with kubectl patch while Flux's data"
    echo "layer was suspended, so the git-to-Flux step isn't part of this drill."
  } >"$evidence"
  echo
  echo "Evidence: $evidence"
}

# Flows Cilium dropped in cnpg-db since the run started, one line each, from
# every agent on both clusters (each agent only sees its own node).
policy_drops() {
  local ctx agent
  for ctx in "$EKS" "$GKE"; do
    for agent in $(kubectl --context "$ctx" --namespace kube-system get pods -l k8s-app=cilium -o name); do
      kubectl --context "$ctx" --namespace kube-system exec "$agent" -c cilium-agent -- \
        hubble observe --namespace "$NS" --verdict DROPPED --since "$started" -o compact 2>/dev/null || true
    done
  done
}

dump_diagnostics() {
  local cluster dir pod
  mkdir -p "$diagnostics"
  policy_drops >"$diagnostics/policy-drops.txt" 2>&1 || true
  for cluster in pg-primary pg-replica; do
    dir=$diagnostics/$cluster
    mkdir -p "$dir"
    k "$cluster" get cluster,backup,pods,pvc -o wide >"$dir/resources.txt" 2>&1 || true
    k "$cluster" get cluster -o yaml >"$dir/clusters.yaml" 2>&1 || true
    k "$cluster" get events --sort-by=.lastTimestamp >"$dir/events.txt" 2>&1 || true
    for pod in $(k "$cluster" get pods -o name 2>/dev/null); do
      k "$cluster" logs "$pod" --all-containers --tail=300 >"$dir/${pod#pod/}.log" 2>&1 || true
    done
  done
  echo "Diagnostics: $diagnostics"
}

# --- Database helpers --------------------------------------------------------

current_primary() { k "$1" get cluster "$1" -o jsonpath='{.status.currentPrimary}'; }

# psql as postgres over the local socket of the cluster's (designated) primary,
# as `kubectl cnpg psql` does.
sql() { # cluster statement
  k "$1" exec "$(current_primary "$1")" -c postgres -- psql -d app -XtAq -v ON_ERROR_STOP=1 -c "$2"
}

# Marks carry the run's stamp, so repeated runs never see each other's rows.
mark() { sql "$1" "INSERT INTO live_drill (run, mark) VALUES ('$stamp', '$2')" >/dev/null; }
has_mark() { [[ $(sql "$1" "SELECT count(*) FROM live_drill WHERE run = '$stamp' AND mark = '$2'") -ge 1 ]]; }
row_count() { sql "$1" "SELECT count(*) FROM live_drill WHERE run = '$stamp'"; }
# Close the current WAL segment so it's archived now, not at archive_timeout.
# Prints the closed segment's name.
switch_wal() { sql "$1" "SELECT pg_walfile_name(pg_switch_wal())"; }
writable() { [[ $(sql "$1" "SELECT NOT pg_is_in_recovery()") == t ]]; }
back_as_replica() { [[ $(sql "$1" "SELECT pg_is_in_recovery()") == t ]]; }
archived_past() { [[ $(sql "$1" "SELECT coalesce(last_archived_wal, '') >= '$2' FROM pg_stat_archiver") == t ]]; }
cluster_ready() { k "$1" wait --for=condition=Ready "cluster/$1" --timeout=5s; }
# A newly promoted primary is restarted in place shortly afterwards, to apply
# settings that only change on restart. Settled: healthy, writable, nothing
# pending a restart, and still so 15s later, after the operator has acted.
settled_once() {
  [[ $(k "$1" get cluster "$1" -o jsonpath='{.status.phase}') == "Cluster in healthy state" ]] &&
    writable "$1" &&
    [[ $(sql "$1" "SELECT count(*) FROM pg_settings WHERE pending_restart") -eq 0 ]]
}
settled() { settled_once "$1" && sleep 15 && settled_once "$1"; }
demotion_token() { k "$1" get cluster "$1" -o jsonpath='{.status.demotionToken}'; }
has_demotion_token() { [[ -n $(demotion_token "$1") ]]; }
spec_primary() { k "$1" get cluster "$1" -o jsonpath='{.spec.replica.primary}'; }
promotion_token() { k "$1" get cluster "$1" -o jsonpath='{.spec.replica.promotionToken}'; }
set_replica() { # cluster json-for-spec.replica
  k "$1" patch cluster "$1" --type merge -p "{\"spec\":{\"replica\":$2}}" >/dev/null
}

# The roles git describes: pg-primary leads and takes writes, pg-replica
# follows, and neither carries a fence or a leftover promotion token.
roles_at_rest() {
  [[ $(spec_primary pg-primary) == pg-primary && $(spec_primary pg-replica) == pg-primary ]] &&
    [[ -z $(k pg-primary get cluster pg-primary -o jsonpath='{.metadata.annotations.cnpg\.io/fencedInstances}') ]] &&
    writable pg-primary && back_as_replica pg-replica
}

# --- Flux --------------------------------------------------------------------

flux_data() { # kube-context jsonpath
  kubectl --context "$1" --namespace flux-system get kustomization data -o jsonpath="$2"
}

suspend_flux() {
  local ctx
  for ctx in "$EKS" "$GKE"; do
    flux --context "$ctx" suspend kustomization data >/dev/null
  done
  suspended=1
}

# Resume Flux only once the live roles match git again; otherwise leave it
# suspended and say why.
restore_flux() {
  [[ $suspended == 1 ]] || return 0
  scenario="restore Flux"
  log "$scenario"
  if ! roles_at_rest; then
    record "roles back where git has them; Flux resumed" FAIL "Flux left suspended on both clusters"
    cat >&2 <<EOF

The roles don't match git, so Flux's data layer stays suspended on both
clusters: resuming it would apply git's roles over the current topology.
spec.replica.primary is $(spec_primary pg-primary || echo '?') on pg-primary and $(spec_primary pg-replica || echo '?') on pg-replica.
Finish or reverse the switchover by hand (docs/deploy.md), check that the live
specs match k8s/data/{aws,gcp}/cluster.yaml, then on each cluster:
  flux --context <context> resume kustomization data
EOF
    return 0
  fi
  # A switch back leaves pg-primary's promotion token in its spec. Git has
  # none, and a stale token must not be there at the next promotion.
  set_replica pg-primary '{"promotionToken":null}'
  set_replica pg-replica '{"promotionToken":null}'
  local ctx resumed=1
  for ctx in "$EKS" "$GKE"; do
    flux --context "$ctx" resume kustomization data --timeout=10m >/dev/null || resumed=0
  done
  if ((resumed)); then
    suspended=0
    record "roles back where git has them; Flux resumed" PASS
  else
    record "roles back where git has them; Flux resumed" FAIL "flux resume didn't report Ready; check flux get kustomizations"
  fi
}

finish() {
  local code=$?
  trap - EXIT
  if ((code != 0)) && ((failures == 0)); then
    record "run aborted (exit $code)" FAIL
  elif ((failures == 0)) && [[ $scenario != finished ]]; then
    record "run stopped before its last scenario (exit $code)" FAIL
  fi
  restore_flux || record "restoring Flux failed" FAIL
  write_evidence
  if ((failures > 0)); then dump_diagnostics; fi
  rm -f "$rows"
  if ((failures > 0)); then exit 1; fi
  exit "$code"
}

# --- Safety ------------------------------------------------------------------

preflight() {
  log "Preflight"
  require_tools kubectl flux tofu python3
  context=$EKS check_cluster_context aws
  context=$GKE check_cluster_context gcp
  local ctx cluster
  for ctx in "$EKS" "$GKE"; do
    if [[ $(flux_data "$ctx" '{.spec.suspend}') == true ]]; then
      echo "Flux's data layer is already suspended on $ctx (an earlier run?); resume it once the roles match git" >&2
      exit 1
    fi
    if [[ $(flux_data "$ctx" '{.status.conditions[?(@.type=="Ready")].status}') != True ]]; then
      echo "Flux's data layer isn't Ready on $ctx; fix that first" >&2
      exit 1
    fi
  done
  for cluster in pg-primary pg-replica; do
    cluster_ready "$cluster" || { echo "$cluster isn't Ready; fix that first" >&2; exit 1; }
    if [[ -n $(promotion_token "$cluster") ]]; then
      echo "$cluster has a promotion token in its spec; git has none" >&2
      exit 1
    fi
  done
  roles_at_rest || { echo "the roles don't match git (pg-primary leading, pg-replica following); refusing to run" >&2; exit 1; }
}

# --- Scenarios ---------------------------------------------------------------

test_replication() {
  begin_scenario "1. replication"
  sql pg-primary "CREATE TABLE IF NOT EXISTS live_drill (id bigserial PRIMARY KEY, run text NOT NULL, mark text NOT NULL, at timestamptz NOT NULL DEFAULT now())" >/dev/null
  mark pg-primary replicated
  local segment start
  segment=$(switch_wal pg-primary)
  start=$(now)
  require "row reaches pg-replica" 300 has_mark pg-replica replicated
  record "row written on pg-primary visible on pg-replica (after a WAL switch)" PASS "$(since "$start")s"
  require "pg-replica archives the segment to GCS" 300 archived_past pg-replica "$segment"
  record "pg-replica archives the same WAL to its own GCS archive" PASS "$(since "$start")s"
}

old_primary=""
new_primary_takes_writes() {
  local current
  current=$(current_primary pg-primary)
  [[ -n $current && $current != "$old_primary" ]] && mark pg-primary after-kill
}

test_kill_primary() {
  begin_scenario "2. kill the primary pod on EKS"
  old_primary=$(current_primary pg-primary)
  mark pg-primary before-kill
  local start
  start=$(now)
  k pg-primary delete pod "$old_primary" --wait=false >/dev/null
  require "a new pg-primary instance takes writes" 600 new_primary_takes_writes
  record "failover to the other instance; writes accepted again" PASS "$(since "$start")s"
  if has_mark pg-primary before-kill; then
    record "row committed before the kill survives" PASS
  else
    record "row committed before the kill survives" FAIL "lost"
  fi
  require "pg-primary healthy again (old pod rejoined)" 900 cluster_ready pg-primary
  switch_wal pg-primary >/dev/null
  start=$(now)
  require "replication continues from the new primary" 300 has_mark pg-replica after-kill
  record "replication continues from the new primary" PASS "$(since "$start")s"
}

old_uid=""
replica_pod_replaced() {
  local pod uid
  pod=$(current_primary pg-replica)
  uid=$(k pg-replica get pod "$pod" -o jsonpath='{.metadata.uid}')
  [[ -n $uid && $uid != "$old_uid" ]] &&
    [[ $(k pg-replica get pod "$pod" -o jsonpath='{.status.containerStatuses[?(@.name=="postgres")].ready}') == true ]]
}

test_lose_replica_pod() {
  begin_scenario "3. lose pg-replica's pod on GKE"
  local pod start
  pod=$(current_primary pg-replica)
  old_uid=$(k pg-replica get pod "$pod" -o jsonpath='{.metadata.uid}')
  start=$(now)
  k pg-replica delete pod "$pod" --wait=false >/dev/null
  require "pg-replica's pod replaced and ready" 900 replica_pod_replaced
  record "pg-replica's pod back and ready" PASS "$(since "$start")s"
  mark pg-primary after-replica-loss
  switch_wal pg-primary >/dev/null
  start=$(now)
  require "pg-replica resumes replaying from S3" 300 has_mark pg-replica after-replica-loss
  record "pg-replica resumes replaying from S3" PASS "$(since "$start")s"
}

test_switchover() {
  begin_scenario "4. planned switchover and back"
  local start token rows_at_demotion
  start=$(now)
  set_replica pg-primary '{"primary":"pg-replica"}'
  require "pg-primary demoted, with a demotion token" 600 has_demotion_token pg-primary
  require "pg-primary back up as a replica after demotion" 600 back_as_replica pg-primary
  rows_at_demotion=$(row_count pg-primary)
  token=$(demotion_token pg-primary)
  set_replica pg-replica "{\"primary\":\"pg-replica\",\"promotionToken\":\"$token\"}"
  require "pg-replica promoted" 900 writable pg-replica
  record "switchover to pg-replica (writes refused meanwhile)" PASS "$(since "$start")s"
  start=$(now)
  require "pg-replica settled after promotion" 600 settled pg-replica
  record "pg-replica settled after promotion (in-place restart)" PASS "$(since "$start")s"
  if [[ $(row_count pg-replica) == "$rows_at_demotion" ]]; then
    record "no row lost in the switchover" PASS "$rows_at_demotion rows"
  else
    record "no row lost in the switchover" FAIL "$rows_at_demotion rows at demotion, $(row_count pg-replica) after promotion"
  fi
  mark pg-replica written-on-gcp
  switch_wal pg-replica >/dev/null
  start=$(now)
  require "pg-primary follows pg-replica through GCS" 300 has_mark pg-primary written-on-gcp
  record "pg-primary replays pg-replica's GCS archive (reverse direction)" PASS "$(since "$start")s"

  start=$(now)
  set_replica pg-replica '{"primary":"pg-primary","promotionToken":null}'
  require "pg-replica demoted, with a demotion token" 600 has_demotion_token pg-replica
  require "pg-replica back up as a replica after demotion" 600 back_as_replica pg-replica
  rows_at_demotion=$(row_count pg-replica)
  token=$(demotion_token pg-replica)
  set_replica pg-primary "{\"primary\":\"pg-primary\",\"promotionToken\":\"$token\"}"
  require "pg-primary promoted" 900 writable pg-primary
  record "switch back to pg-primary" PASS "$(since "$start")s"
  start=$(now)
  require "pg-primary settled after promotion" 600 settled pg-primary
  record "pg-primary settled after promotion (in-place restart)" PASS "$(since "$start")s"
  if [[ $(row_count pg-primary) == "$rows_at_demotion" ]]; then
    record "no row lost in the switch back" PASS "$rows_at_demotion rows"
  else
    record "no row lost in the switch back" FAIL "$rows_at_demotion rows at demotion, $(row_count pg-primary) after promotion"
  fi
  mark pg-primary after-switchback
  switch_wal pg-primary >/dev/null
  start=$(now)
  require "pg-replica follows pg-primary again" 300 has_mark pg-replica after-switchback
  record "replication from pg-primary resumes" PASS "$(since "$start")s"
}

test_policy_drops() {
  begin_scenario "5. network policy"
  local drops count
  drops=$(policy_drops | grep -v '^$' || true)
  count=$(grep -c . <<<"$drops" || true)
  record "flows dropped by policy in $NS during the run" INFO "$count"
  if ((count > 0)); then
    echo "    first drops (all of them: rerun with hubble observe --verdict DROPPED):"
    head -5 <<<"$drops" | sed 's/^/      /'
  fi
}

# --- Main --------------------------------------------------------------------

# A refused preflight writes no evidence: nothing was tested or changed.
preflight
trap finish EXIT
log "Suspending Flux's data layer on both clusters"
suspend_flux
test_replication
test_kill_primary
test_lose_replica_pod
test_switchover
test_policy_drops
scenario=finished
