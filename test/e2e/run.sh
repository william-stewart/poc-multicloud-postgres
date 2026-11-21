#!/usr/bin/env bash
# End-to-end test of the data layer on a local, single-node Kubernetes cluster
# (Rancher Desktop by default). It runs the real k8s/data manifests, adapted
# only where a cloud can't exist locally (test/e2e/manifests/emulate), with
# the chart versions and values Flux installs, against a local S3 server that
# stands in for both S3 and GCS. Then it breaks things and measures:
#
#   1. Replication: a row written on pg-primary appears on pg-replica.
#   2. GCP copy restores alone: point-in-time restore from pg-replica's
#      archive only, to a target between two rows.
#   3. Kill the primary pod: in-cluster failover, no committed row lost.
#   4. Object store outage: writes continue, archiving is reported failing,
#      and the replica catches up once the store is back.
#   5. Planned switchover to pg-replica and back, with promotion tokens: no
#      row lost, and replication runs in both directions.
#   6. Unplanned failover with fencing: the fenced primary stops, pg-replica
#      takes writes, and the rows lost are counted.
#
# Measurements go to evidence/e2e/<UTC time>.md (commit it as the record of
# the run); diagnostics from a failed run go to test/e2e/results/ (ignored).
#
# Usage (make e2e / make e2e-clean):
#   test/e2e/run.sh            run everything, then remove what it installed
#   test/e2e/run.sh --clean    only remove what a previous run installed
# Environment:
#   E2E_CONTEXT  kube context to use (default rancher-desktop); it must point
#                at a local API server, so this can never touch a cloud cluster
#   E2E_KEEP=1   leave everything installed after the run, for inspection
set -euo pipefail

CONTEXT=${E2E_CONTEXT:-rancher-desktop}
KEEP=${E2E_KEEP:-0}
NS=cnpg-db
cd "$(git rev-parse --show-toplevel)"

kc() { kubectl --context "$CONTEXT" "$@"; }
hc() { helm --kube-context "$CONTEXT" "$@"; }
log() { printf '\n==> %s\n' "$*"; }
now() { python3 -c 'import time; print(f"{time.time():.1f}")'; }
since() { python3 -c 'import sys, time; print(f"{time.time() - float(sys.argv[1]):.1f}")' "$1"; }

# --- Safety ------------------------------------------------------------------

preflight() {
  local tool server
  for tool in kubectl helm kustomize python3 openssl; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
  done
  server=$(kubectl config view --minify --context "$CONTEXT" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  if [[ ! $server =~ ^https?://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?/?$ ]]; then
    echo "context $CONTEXT points at '${server:-nothing}', not a local API server; refusing to run" >&2
    exit 1
  fi
  kc get nodes >/dev/null
  # Four PostgreSQL pods at once (pg-primary x2, pg-replica, pg-restore), each
  # Guaranteed 300m CPU and 512Mi with its sidecar, plus the operators.
  kc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu} {.status.allocatable.memory}{"\n"}{end}' |
    python3 -c '
import sys
cpu = mem = 0.0
for line in sys.stdin:
    c, m = line.split()
    cpu += float(c[:-1]) / 1000 if c.endswith("m") else float(c)
    units = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30}
    mem += float(m[:-2]) * units[m[-2:]] / 2**30 if m[-2:] in units else float(m) / 2**30
if cpu < 3 or mem < 6:
    print(f"warning: the cluster has {cpu:.1f} CPUs and {mem:.1f}Gi allocatable; 4 CPUs and 8Gi"
          " (Rancher Desktop: Preferences > Virtual Machine) avoid pods pending for resources",
          file=sys.stderr)
'
}

# --- Results -----------------------------------------------------------------

stamp=$(date -u +%Y%m%dT%H%M%SZ)
evidence=evidence/e2e/$stamp.md
diagnostics=test/e2e/results/$stamp
rows=$(mktemp)
failures=0
scenario=setup

record() { # check result measurement
  printf '| %s | %s | %s | %s |\n' "$scenario" "$1" "$2" "${3:-}" >>"$rows"
  printf '    [%s] %s %s\n' "$2" "$1" "${3:+($3)}"
  if [[ $2 == FAIL ]]; then failures=$((failures + 1)); fi
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

wait_until() { # timeout command...
  local timeout=$1 start
  shift
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if (($(date +%s) - start > timeout)); then return 1; fi
    sleep 2
  done
}

write_evidence() {
  local status=PASS
  if ((failures > 0)); then status=FAIL; fi
  mkdir -p "$(dirname "$evidence")"
  {
    echo "# End-to-end run $stamp"
    echo
    echo "- Result: **$status** ($failures failed checks)"
    echo "- Commit: $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- k8s test/e2e || echo ' (with uncommitted changes)')"
    echo "- Kubernetes: $(kc version -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null || echo unknown), $(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ') node(s), context $CONTEXT"
    echo "- Charts: cert-manager $(chart_version cert-manager), cloudnative-pg $(chart_version cloudnative-pg), plugin-barman-cloud $(chart_version plugin-barman-cloud)"
    echo "- PostgreSQL: $(sed -n 's/^ *value: *//p' k8s/data/components/postgres-image/kustomization.yaml)"
    echo
    echo "| Scenario | Check | Result | Measurement |"
    echo "| --- | --- | --- | --- |"
    cat "$rows"
    echo
    echo "Emulated, not tested here: cloud identities (IRSA, GKE Workload Identity and"
    echo "both federations) and network policies (Cilium). Both archives live on one"
    echo "local S3 server, and both clusters on one node. Everything else is the"
    echo "manifests production runs, including archive_timeout (60s)."
  } >"$evidence"
  echo
  echo "Evidence: $evidence"
}

dump_diagnostics() {
  mkdir -p "$diagnostics"
  kc -n "$NS" get cluster,backup,pods,pvc -o wide >"$diagnostics/resources.txt" 2>&1 || true
  kc -n "$NS" get cluster -o yaml >"$diagnostics/clusters.yaml" 2>&1 || true
  kc -n "$NS" get events --sort-by=.lastTimestamp >"$diagnostics/events.txt" 2>&1 || true
  kc -n cnpg-system logs deploy/cloudnative-pg --tail=500 >"$diagnostics/operator.log" 2>&1 || true
  kc -n cnpg-system logs deploy/plugin-barman-cloud --tail=500 >"$diagnostics/plugin.log" 2>&1 || true
  local pod container
  for pod in $(kc -n "$NS" get pods -o name 2>/dev/null); do
    kc -n "$NS" logs "$pod" --all-containers --tail=300 >"$diagnostics/${pod#pod/}.log" 2>&1 || true
    # Why each container last stopped (OOMKilled, Error, exit code), which
    # neither the events nor the current logs show.
    kc -n "$NS" get "$pod" -o jsonpath='{range .status.containerStatuses[*]}{.name}{" restarts="}{.restartCount}{" last="}{.lastState.terminated.reason}{" exit="}{.lastState.terminated.exitCode}{"\n"}{end}' 2>&1 |
      sed "s|^|${pod#pod/} |" >>"$diagnostics/container-status.txt" || true
    # Logs of a container's previous run, lost from the line above once it restarts.
    for container in $(kc -n "$NS" get "$pod" -o jsonpath='{range .status.containerStatuses[?(@.restartCount>0)]}{.name}{" "}{end}' 2>/dev/null); do
      kc -n "$NS" logs "$pod" -c "$container" --previous --tail=300 \
        >"$diagnostics/${pod#pod/}.$container.previous.log" 2>&1 || true
    done
  done
  echo "Diagnostics: $diagnostics"
}

finish() {
  local code=$?
  trap - EXIT
  if [[ $scenario != clean ]]; then
    if ((code != 0)) && ((failures == 0)); then record "run aborted (exit $code)" FAIL; fi
    write_evidence
    if ((failures > 0)); then dump_diagnostics; fi
    if [[ $KEEP == 1 ]]; then echo "E2E_KEEP=1: left installed; remove with make e2e-clean"; else clean; fi
  fi
  rm -f "$rows"
  if ((failures > 0)); then exit 1; fi
  exit "$code"
}

# --- Install and remove --------------------------------------------------------

chart_version() {
  sed -n 's/^ *version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "k8s/platform/base/$1/helmrelease.yaml" | head -1
}

clean() {
  log "Removing what the end-to-end test installed"
  kc delete namespace "$NS" s3-emulator --ignore-not-found --wait=true --timeout=5m || true
  hc uninstall plugin-barman-cloud --namespace cnpg-system --ignore-not-found --wait || true
  hc uninstall cloudnative-pg --namespace cnpg-system --ignore-not-found --wait || true
  hc uninstall cert-manager --namespace cert-manager --ignore-not-found --wait || true
  kc delete namespace cnpg-system cert-manager --ignore-not-found --wait=true --timeout=5m || true
}

install_platform() {
  local values
  for values in cert-manager cloudnative-pg plugin-barman-cloud; do
    # shellcheck disable=SC2016  # a literal ${, not an expansion
    if grep -qF '${' "k8s/platform/base/$values/values.yaml"; then
      echo "k8s/platform/base/$values/values.yaml uses variables; teach run.sh to fill them" >&2
      exit 1
    fi
  done
  log "cert-manager $(chart_version cert-manager)"
  hc upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --version "$(chart_version cert-manager)" --namespace cert-manager --create-namespace \
    -f k8s/platform/base/cert-manager/values.yaml --wait --timeout 10m
  log "CloudNativePG $(chart_version cloudnative-pg)"
  hc upgrade --install cloudnative-pg cloudnative-pg --repo https://cloudnative-pg.github.io/charts \
    --version "$(chart_version cloudnative-pg)" --namespace cnpg-system --create-namespace \
    -f k8s/platform/base/cloudnative-pg/values.yaml --wait --timeout 10m
  log "Barman Cloud plugin $(chart_version plugin-barman-cloud)"
  hc upgrade --install plugin-barman-cloud plugin-barman-cloud --repo https://cloudnative-pg.github.io/charts \
    --version "$(chart_version plugin-barman-cloud)" --namespace cnpg-system \
    -f k8s/platform/base/plugin-barman-cloud/values.yaml --wait --timeout 10m
}

deploy_object_store() {
  local key secret
  log "Local S3 server (SeaweedFS) with fresh credentials"
  key=$(openssl rand -hex 10)
  secret=$(openssl rand -hex 20)
  for ns in s3-emulator "$NS"; do
    kc create namespace "$ns" --dry-run=client -o yaml | kc apply -f - >/dev/null
  done
  # Process substitution: the credentials pass through pipes, never a file.
  kc -n s3-emulator create secret generic seaweedfs-s3 --from-file=s3.json=<(printf \
    '{"identities":[{"name":"barman","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","List","Write","Tagging"]}]}' \
    "$key" "$secret") --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n "$NS" create secret generic s3-emulator \
    --from-env-file=<(printf 'ACCESS_KEY_ID=%s\nACCESS_SECRET_KEY=%s\n' "$key" "$secret") \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc apply -k test/e2e/manifests/s3 >/dev/null
  kc -n s3-emulator rollout status deployment/seaweedfs --timeout=5m
  local bucket
  for bucket in aws-archive gcs-archive; do
    require "create bucket $bucket" 120 kc -n s3-emulator exec deploy/seaweedfs -- \
      sh -c "echo 's3.bucket.create -name $bucket' | weed shell >/dev/null && echo 's3.bucket.list' | weed shell | grep -q $bucket"
  done
}

app_owner_secret() {
  kc -n "$NS" create secret generic app-owner --type=kubernetes.io/basic-auth \
    --from-env-file=<(printf 'username=app\npassword=%s\n' "$(openssl rand -hex 16)") \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
}

apply_overlay() { # directory
  local manifests
  manifests=$(kustomize build "$1")
  # shellcheck disable=SC2016  # a literal ${, not an expansion
  if grep -qF '${' <<<"$manifests"; then
    echo "$1 still has \${VARS} after rendering" >&2
    exit 1
  fi
  kc apply -f - <<<"$manifests" >/dev/null
}

# --- Database helpers --------------------------------------------------------

current_primary() { kc -n "$NS" get cluster "$1" -o jsonpath='{.status.currentPrimary}'; }

# psql as postgres over the local socket of the cluster's (designated) primary,
# as `kubectl cnpg psql` does.
sql() { # cluster statement
  kc -n "$NS" exec "$(current_primary "$1")" -c postgres -- psql -d app -XtAq -v ON_ERROR_STOP=1 -c "$2"
}

mark() { sql "$1" "INSERT INTO e2e (mark) VALUES ('$2')" >/dev/null; }
# Close the current WAL segment so it's archived now, not at archive_timeout.
# Prints the closed segment's name.
switch_wal() { sql "$1" "SELECT pg_walfile_name(pg_switch_wal())"; }
has_mark() { [[ $(sql "$1" "SELECT count(*) FROM e2e WHERE mark = '$2'") -ge 1 ]]; }
lacks_mark() { [[ $(sql "$1" "SELECT count(*) FROM e2e WHERE mark = '$2'") -eq 0 ]]; }
writable() { [[ $(sql "$1" "SELECT NOT pg_is_in_recovery()") == t ]]; }
row_count() { sql "$1" "SELECT count(*) FROM e2e"; }
archived_past() { [[ $(sql "$1" "SELECT coalesce(last_archived_wal, '') >= '$2' FROM pg_stat_archiver") == t ]]; }
cluster_ready() { kc -n "$NS" wait --for=condition=Ready "cluster/$1" --timeout=5s; }
condition_is() { # cluster type status
  [[ $(kc -n "$NS" get cluster "$1" -o jsonpath="{.status.conditions[?(@.type==\"$2\")].status}") == "$3" ]]
}
backup_completed() {
  kc -n "$NS" get backup -o jsonpath="{.items[?(@.spec.cluster.name==\"$1\")].status.phase}" | grep -qw completed
}
demotion_token() { kc -n "$NS" get cluster "$1" -o jsonpath='{.status.demotionToken}'; }
has_demotion_token() { [[ -n $(demotion_token "$1") ]]; }
set_replica() { # cluster json-for-spec.replica
  kc -n "$NS" patch cluster "$1" --type merge -p "{\"spec\":{\"replica\":$2}}" >/dev/null
}

# --- Scenarios ---------------------------------------------------------------

deploy_databases() {
  scenario="0. deploy"
  log "pg-primary (k8s/data/aws, emulated)"
  app_owner_secret
  apply_overlay test/e2e/manifests/primary
  local start
  start=$(now)
  require "pg-primary ready" 900 cluster_ready pg-primary
  require "pg-primary first base backup" 600 backup_completed pg-primary
  record "pg-primary ready with its first backup" PASS "$(since "$start")s"

  log "pg-replica (k8s/data/gcp, emulated)"
  apply_overlay test/e2e/manifests/replica
  start=$(now)
  require "pg-replica ready" 900 cluster_ready pg-replica
  require "pg-replica first base backup, to its own archive" 600 backup_completed pg-replica
  record "pg-replica bootstrapped from pg-primary's archive, with its own first backup" PASS "$(since "$start")s"
}

test_replication() {
  scenario="1. replication"
  log "$scenario"
  sql pg-primary "CREATE TABLE e2e (id bigserial PRIMARY KEY, mark text NOT NULL, at timestamptz NOT NULL DEFAULT now())" >/dev/null
  mark pg-primary replicated
  switch_wal pg-primary >/dev/null
  local start
  start=$(now)
  require "row reaches pg-replica" 300 has_mark pg-replica replicated
  record "row written on pg-primary visible on pg-replica (after a WAL switch)" PASS "$(since "$start")s"
}

test_restore_from_gcp_copy() {
  scenario="2. restore from the GCP copy"
  log "$scenario"
  local target segment start
  mark pg-primary before-target
  target=$(sql pg-primary "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00'")
  sleep 2
  mark pg-primary after-target
  segment=$(switch_wal pg-primary)
  require "pg-replica replays past the target" 300 has_mark pg-replica after-target
  require "pg-replica archives the target's WAL to its own archive" 300 archived_past pg-replica "$segment"

  kustomize build test/e2e/manifests/restore | sed "s|__TARGET_TIME__|$target|" | kc apply -f - >/dev/null
  start=$(now)
  require "pg-restore ready" 900 cluster_ready pg-restore
  record "point-in-time restore from pg-replica's archive alone" PASS "$(since "$start")s"
  if has_mark pg-restore before-target && lacks_mark pg-restore after-target; then
    record "restored exactly to the target time ($target)" PASS
  else
    record "restored exactly to the target time ($target)" FAIL "rows before/after the target don't match"
  fi
  kc -n "$NS" delete cluster pg-restore --wait=true --timeout=5m >/dev/null
}

old_primary=""
new_primary_takes_writes() {
  local current
  current=$(current_primary pg-primary)
  [[ -n $current && $current != "$old_primary" ]] && mark pg-primary after-kill
}

test_kill_primary() {
  scenario="3. kill the primary pod"
  log "$scenario"
  old_primary=$(current_primary pg-primary)
  mark pg-primary before-kill
  local start
  start=$(now)
  kc -n "$NS" delete pod "$old_primary" --grace-period=0 --force >/dev/null 2>&1
  require "a new pg-primary instance takes writes" 300 new_primary_takes_writes
  record "failover to the other instance; writes accepted again" PASS "$(since "$start")s"
  if has_mark pg-primary before-kill; then
    record "row committed before the kill survives" PASS
  else
    record "row committed before the kill survives" FAIL "lost"
  fi
  require "pg-primary healthy again (old pod rejoined)" 600 cluster_ready pg-primary
  switch_wal pg-primary >/dev/null
  start=$(now)
  require "archiving continues from the new primary" 300 has_mark pg-replica after-kill
  record "replication continues from the new primary" PASS "$(since "$start")s"
}

test_object_store_outage() {
  scenario="4. object store outage"
  log "$scenario"
  local start down
  kc -n s3-emulator scale deployment/seaweedfs --replicas=0 >/dev/null
  kc -n s3-emulator wait --for=delete pod -l app=seaweedfs --timeout=2m >/dev/null 2>&1 || true
  down=$(now)
  if mark pg-primary during-outage; then
    record "pg-primary keeps accepting writes" PASS
  else
    record "pg-primary keeps accepting writes" FAIL
  fi
  switch_wal pg-primary >/dev/null
  if wait_until 300 condition_is pg-primary ContinuousArchiving False; then
    record "CloudNativePG reports archiving failing (ContinuousArchiving=False)" PASS "$(since "$down")s after the outage"
  else
    record "CloudNativePG reports archiving failing (ContinuousArchiving=False)" FAIL "not within 300s"
  fi
  if lacks_mark pg-replica during-outage; then
    record "pg-replica stops at the last archived WAL" PASS
  else
    record "pg-replica stops at the last archived WAL" FAIL "saw a row that was never archived"
  fi
  record "outage duration" INFO "$(since "$down")s"

  kc -n s3-emulator scale deployment/seaweedfs --replicas=1 >/dev/null
  kc -n s3-emulator rollout status deployment/seaweedfs --timeout=5m >/dev/null
  start=$(now)
  require "pg-replica catches up after the outage" 900 has_mark pg-replica during-outage
  record "pg-replica catches up once the store is back" PASS "$(since "$start")s"
  if wait_until 300 condition_is pg-primary ContinuousArchiving True; then
    record "archiving reported healthy again" PASS
  else
    record "archiving reported healthy again" FAIL "not within 300s"
  fi
}

test_switchover() {
  scenario="5. planned switchover and back"
  log "$scenario"
  local start token rows_at_demotion
  start=$(now)
  set_replica pg-primary '{"primary":"pg-replica"}'
  require "pg-primary demoted, with a demotion token" 300 has_demotion_token pg-primary
  rows_at_demotion=$(row_count pg-primary)
  token=$(demotion_token pg-primary)
  set_replica pg-replica "{\"primary\":\"pg-replica\",\"promotionToken\":\"$token\"}"
  require "pg-replica promoted" 900 writable pg-replica
  record "switchover to pg-replica (writes refused meanwhile)" PASS "$(since "$start")s"
  if [[ $(row_count pg-replica) == "$rows_at_demotion" ]]; then
    record "no row lost in the switchover" PASS "$rows_at_demotion rows"
  else
    record "no row lost in the switchover" FAIL "$rows_at_demotion rows at demotion, $(row_count pg-replica) after promotion"
  fi
  mark pg-replica written-on-gcp
  switch_wal pg-replica >/dev/null
  start=$(now)
  require "pg-primary follows pg-replica" 300 has_mark pg-primary written-on-gcp
  record "pg-primary replays pg-replica's archive (reverse direction)" PASS "$(since "$start")s"

  start=$(now)
  set_replica pg-replica '{"primary":"pg-primary","promotionToken":null}'
  require "pg-replica demoted, with a demotion token" 300 has_demotion_token pg-replica
  rows_at_demotion=$(row_count pg-replica)
  token=$(demotion_token pg-replica)
  set_replica pg-primary "{\"primary\":\"pg-primary\",\"promotionToken\":\"$token\"}"
  require "pg-primary promoted" 900 writable pg-primary
  record "switch back to pg-primary" PASS "$(since "$start")s"
  if [[ $(row_count pg-primary) == "$rows_at_demotion" ]]; then
    record "no row lost in the switch back" PASS "$rows_at_demotion rows"
  else
    record "no row lost in the switch back" FAIL "$rows_at_demotion rows at demotion, $(row_count pg-primary) after promotion"
  fi
  mark pg-primary after-switchback
  switch_wal pg-primary >/dev/null
  require "pg-replica follows pg-primary again" 300 has_mark pg-replica after-switchback
  record "replication from pg-primary resumes" PASS
}

primary_fenced() { ! sql pg-primary "SELECT 1"; }

test_unplanned_failover() {
  scenario="6. unplanned failover"
  log "$scenario"
  local i start written=10 surviving
  # Steady writes with no WAL switch, as in production: only archive_timeout
  # (60s) ships them, so the last ones are what a sudden loss costs.
  for i in $(seq 1 "$written"); do
    mark pg-primary "rpo-$i"
    sleep 1
  done
  start=$(now)
  # The runbook's single commit: fence and demote pg-primary, promote
  # pg-replica with no token.
  kc -n "$NS" annotate cluster pg-primary 'cnpg.io/fencedInstances=["*"]' --overwrite >/dev/null
  set_replica pg-primary '{"primary":"pg-replica","promotionToken":null}'
  set_replica pg-replica '{"primary":"pg-replica","promotionToken":null}'
  require "pg-replica promoted without a token" 900 writable pg-replica
  record "failover to pg-replica" PASS "$(since "$start")s"
  surviving=$(sql pg-replica "SELECT count(*) FROM e2e WHERE mark LIKE 'rpo-%'")
  record "rows lost from the last ${written}s of writes (RPO)" INFO "$((written - surviving)) of $written; archive_timeout is 60s"
  if wait_until 120 primary_fenced; then
    record "fenced pg-primary refuses connections" PASS
  else
    record "fenced pg-primary refuses connections" FAIL "still answering after 120s"
  fi
  if mark pg-replica after-failover; then
    record "pg-replica takes writes" PASS
  else
    record "pg-replica takes writes" FAIL
  fi
}

# --- Main --------------------------------------------------------------------

preflight
if [[ ${1:-} == --clean ]]; then
  scenario=clean
  clean
  exit 0
fi
[[ $# -eq 0 ]] || { echo "usage: $0 [--clean]" >&2; exit 2; }

trap finish EXIT
if kc get namespace "$NS" >/dev/null 2>&1; then
  log "Leftovers from an earlier run found; starting clean"
  clean
fi
install_platform
deploy_object_store
deploy_databases
test_replication
test_restore_from_gcp_copy
test_kill_primary
test_object_store_outage
test_switchover
test_unplanned_failover
