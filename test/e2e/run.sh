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
#   E2E_MONITORING=1
#                also install Prometheus and Grafana from k8s/monitoring before
#                the databases, so the dashboard records the whole run; open it
#                with make e2e-grafana (with E2E_KEEP=1 it outlives the run).
#                Each scenario is marked on the dashboard as a labeled region.
set -euo pipefail

CONTEXT=${E2E_CONTEXT:-rancher-desktop}
KEEP=${E2E_KEEP:-0}
MONITORING=${E2E_MONITORING:-0}
MONITORING_RELEASE=k8s/monitoring/kube-prometheus-stack/helmrelease.yaml
# With monitoring on: the run's own port-forward to Grafana, its admin login
# (user:password, never written to disk), and the open scenario's region.
grafana_url="" grafana_login="" forward_pid="" annotation_id=""
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
  # Prometheus and Grafana add about 1Gi.
  kc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu} {.status.allocatable.memory}{"\n"}{end}' |
    python3 -c '
import sys
monitoring = sys.argv[1] == "1"
cpu = mem = 0.0
for line in sys.stdin:
    c, m = line.split()
    cpu += float(c[:-1]) / 1000 if c.endswith("m") else float(c)
    units = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30}
    mem += float(m[:-2]) * units[m[-2:]] / 2**30 if m[-2:] in units else float(m) / 2**30
low, want = (7, 10) if monitoring else (6, 8)
if cpu < 3 or mem < low:
    print(f"warning: the cluster has {cpu:.1f} CPUs and {mem:.1f}Gi allocatable; 4 CPUs and {want}Gi"
          " (Rancher Desktop: Preferences > Virtual Machine) avoid pods pending for resources",
          file=sys.stderr)
' "$MONITORING"
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
    echo "- Charts: cert-manager $(chart_version cert-manager), cloudnative-pg $(chart_version cloudnative-pg), plugin-barman-cloud $(chart_version plugin-barman-cloud)$(
      if [[ $MONITORING == 1 ]]; then echo ", kube-prometheus-stack $(release_version "$MONITORING_RELEASE")"; fi)"
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
    # The Barman plugin runs as a native sidecar, so its status is under
    # initContainerStatuses.
    kc -n "$NS" get "$pod" -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{" restarts="}{.restartCount}{" last="}{.lastState.terminated.reason}{" exit="}{.lastState.terminated.exitCode}{"\n"}{end}{range .status.containerStatuses[*]}{.name}{" restarts="}{.restartCount}{" last="}{.lastState.terminated.reason}{" exit="}{.lastState.terminated.exitCode}{"\n"}{end}' 2>&1 |
      sed "s|^|${pod#pod/} |" >>"$diagnostics/container-status.txt" || true
    # Logs of a container's previous run, lost from the line above once it restarts.
    for container in $(kc -n "$NS" get "$pod" -o jsonpath='{range .status.initContainerStatuses[?(@.restartCount>0)]}{.name}{" "}{end}{range .status.containerStatuses[?(@.restartCount>0)]}{.name}{" "}{end}' 2>/dev/null); do
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
    mark_scenario || true
    disconnect_grafana || true
    if ((code != 0)) && ((failures == 0)); then
      record "run aborted (exit $code)" FAIL
    elif ((failures == 0)) && [[ $scenario != finished ]]; then
      # Exited 0 without reaching the end, as when bash hits a syntax error
      # after run.sh is edited mid-run: never a pass.
      record "run stopped before its last scenario (exit $code)" FAIL
    fi
    write_evidence
    if ((failures > 0)); then dump_diagnostics; fi
    if [[ $KEEP == 1 ]]; then echo "E2E_KEEP=1: left installed; remove with make e2e-clean"; else clean; fi
  fi
  rm -f "$rows"
  if ((failures > 0)); then exit 1; fi
  exit "$code"
}

# --- Install and remove --------------------------------------------------------

release_version() { # helmrelease.yaml
  sed -n 's/^ *version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$1" | head -1
}
chart_version() { release_version "k8s/platform/base/$1/helmrelease.yaml"; }

clean() {
  log "Removing what the end-to-end test installed"
  kc delete namespace "$NS" s3-emulator --ignore-not-found --wait=true --timeout=5m || true
  # Whether or not this run installed it. The Prometheus Operator's CRDs stay:
  # Helm never deletes CRDs, and another install may be using them.
  hc uninstall kube-prometheus-stack --namespace monitoring --ignore-not-found --wait || true
  kc delete namespace monitoring --ignore-not-found --wait=true --timeout=5m || true
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

# Prometheus and Grafana, with the version and values in k8s/monitoring, and
# the PodMonitor and dashboard from k8s/monitoring/config.
install_monitoring() {
  local values=k8s/monitoring/kube-prometheus-stack/values.yaml version
  version=$(release_version "$MONITORING_RELEASE")
  # shellcheck disable=SC2016  # a literal ${, not an expansion
  if grep -qF '${' "$values"; then
    echo "$values uses variables; teach run.sh to fill them" >&2
    exit 1
  fi
  log "Prometheus and Grafana (kube-prometheus-stack $version)"
  # The dashboard only watches the test, so a monitoring stack that doesn't
  # come up is a warning, not a failed run.
  if ! hc upgrade --install kube-prometheus-stack kube-prometheus-stack \
    --repo https://prometheus-community.github.io/helm-charts \
    --version "$version" --namespace monitoring --create-namespace \
    -f "$values" --wait --timeout 5m; then
    echo "warning: Prometheus or Grafana isn't ready; continuing without waiting for them" >&2
    kc -n monitoring get pods >&2 || true
  fi
  if kc apply -k k8s/monitoring/config >/dev/null; then
    echo "Dashboard: run make e2e-grafana in another terminal, then open http://localhost:3000/d/postgres-dr"
    connect_grafana
  else
    echo "warning: couldn't apply k8s/monitoring/config; the dashboard will be empty" >&2
  fi
}

# --- Scenario marks on the dashboard -----------------------------------------
# Best effort: if Grafana can't be reached, the run goes on unmarked.

grafana_api() { # method path [json]
  local args=(-fsS -X "$1" -H 'Content-Type: application/json')
  if [[ $# -gt 2 ]]; then args+=(--data "$3"); fi
  # The login goes through a file descriptor, not the command line.
  curl "${args[@]}" --config <(printf 'user = "%s"\n' "$grafana_login") "$grafana_url$2"
}

connect_grafana() {
  local user password forward_log port
  if ! user=$(kc -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-user}' | base64 --decode) ||
    ! password=$(kc -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 --decode); then
    echo "warning: no Grafana login found; scenarios won't be marked on the dashboard" >&2
    return 0
  fi
  forward_log=$(mktemp)
  kc -n monitoring port-forward svc/kube-prometheus-stack-grafana :80 >"$forward_log" 2>&1 &
  forward_pid=$!
  if wait_until 30 grep -q '^Forwarding from 127\.0\.0\.1:' "$forward_log"; then
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$forward_log" | head -1)
    grafana_url=http://127.0.0.1:$port
    grafana_login=$user:$password
  fi
  rm -f "$forward_log"
  if [[ -z $grafana_url ]] || ! wait_until 120 grafana_api GET /api/health; then
    echo "warning: can't reach Grafana; scenarios won't be marked on the dashboard" >&2
    disconnect_grafana
  fi
}

disconnect_grafana() {
  if [[ -n $forward_pid ]]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
  forward_pid="" grafana_url="" grafana_login=""
}

# Closes the open scenario's region, then opens one for the named scenario
# (none when called without a name, at the end of the run).
mark_scenario() { # [name]
  [[ -n $grafana_url ]] || return 0
  local now_ms body
  now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
  if [[ -n $annotation_id ]]; then
    grafana_api PATCH "/api/annotations/$annotation_id" "{\"timeEnd\": $now_ms}" >/dev/null 2>&1 || true
    annotation_id=""
  fi
  [[ $# -gt 0 ]] || return 0
  body=$(python3 -c 'import json, sys; t = int(sys.argv[1]); print(json.dumps({"time": t, "timeEnd": t, "tags": ["e2e"], "text": sys.argv[2]}))' "$now_ms" "$1")
  if ! annotation_id=$(grafana_api POST /api/annotations "$body" 2>/dev/null |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])' 2>/dev/null); then
    annotation_id=""
    echo "warning: Grafana refused a scenario mark; the rest of the run goes unmarked" >&2
    disconnect_grafana
  fi
}

begin_scenario() { # name
  scenario=$1
  log "$scenario"
  mark_scenario "$scenario"
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
# Demotion publishes its token before the instance restarts as a replica;
# queries fail with "starting up" until it is back.
back_as_replica() { [[ $(sql "$1" "SELECT pg_is_in_recovery()") == t ]]; }
row_count() { sql "$1" "SELECT count(*) FROM e2e"; }
# A newly promoted primary is restarted in place shortly afterwards, to apply
# settings that only change on restart. Settled: healthy, writable, nothing
# pending a restart, and still so 15s later, after the operator has acted.
settled_once() {
  [[ $(kc -n "$NS" get cluster "$1" -o jsonpath='{.status.phase}') == "Cluster in healthy state" ]] &&
    writable "$1" &&
    [[ $(sql "$1" "SELECT count(*) FROM pg_settings WHERE pending_restart") -eq 0 ]]
}
settled() { settled_once "$1" && sleep 15 && settled_once "$1"; }
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
  mark_scenario "$scenario"
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
  begin_scenario "1. replication"
  sql pg-primary "CREATE TABLE e2e (id bigserial PRIMARY KEY, mark text NOT NULL, at timestamptz NOT NULL DEFAULT now())" >/dev/null
  mark pg-primary replicated
  switch_wal pg-primary >/dev/null
  local start
  start=$(now)
  require "row reaches pg-replica" 300 has_mark pg-replica replicated
  record "row written on pg-primary visible on pg-replica (after a WAL switch)" PASS "$(since "$start")s"
}

test_restore_from_gcp_copy() {
  begin_scenario "2. restore from the GCP copy"
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
  begin_scenario "3. kill the primary pod"
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
  begin_scenario "4. object store outage"
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
  begin_scenario "5. planned switchover and back"
  local start token rows_at_demotion
  start=$(now)
  set_replica pg-primary '{"primary":"pg-replica"}'
  require "pg-primary demoted, with a demotion token" 300 has_demotion_token pg-primary
  require "pg-primary back up as a replica after demotion" 300 back_as_replica pg-primary
  rows_at_demotion=$(row_count pg-primary)
  token=$(demotion_token pg-primary)
  set_replica pg-replica "{\"primary\":\"pg-replica\",\"promotionToken\":\"$token\"}"
  require "pg-replica promoted" 900 writable pg-replica
  record "switchover to pg-replica (writes refused meanwhile)" PASS "$(since "$start")s"
  start=$(now)
  require "pg-replica settled after promotion" 300 settled pg-replica
  record "pg-replica settled after promotion (in-place restart)" PASS "$(since "$start")s"
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
  require "pg-replica back up as a replica after demotion" 300 back_as_replica pg-replica
  rows_at_demotion=$(row_count pg-replica)
  token=$(demotion_token pg-replica)
  set_replica pg-primary "{\"primary\":\"pg-primary\",\"promotionToken\":\"$token\"}"
  require "pg-primary promoted" 900 writable pg-primary
  record "switch back to pg-primary" PASS "$(since "$start")s"
  start=$(now)
  require "pg-primary settled after promotion" 300 settled pg-primary
  record "pg-primary settled after promotion (in-place restart)" PASS "$(since "$start")s"
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
  begin_scenario "6. unplanned failover"
  local i start written=10 surviving
  # Steady writes with no WAL switch, as in production: only archive_timeout
  # (60s) ships them, so the last ones are what a sudden loss costs.
  for i in $(seq 1 "$written"); do
    mark pg-primary "rpo-$i"
    sleep 1
  done
  start=$(now)
  # The runbook's single commit: fence pg-primary (not demote: demoting
  # restarts it, and the restart lifts the fence), promote pg-replica with no
  # token.
  kc -n "$NS" annotate cluster pg-primary 'cnpg.io/fencedInstances=["*"]' --overwrite >/dev/null
  set_replica pg-replica '{"primary":"pg-replica","promotionToken":null}'
  require "pg-replica promoted without a token" 900 writable pg-replica
  record "failover to pg-replica" PASS "$(since "$start")s"
  start=$(now)
  require "pg-replica settled after promotion" 300 settled pg-replica
  record "pg-replica settled after promotion (in-place restart)" PASS "$(since "$start")s"
  surviving=$(sql pg-replica "SELECT count(*) FROM e2e WHERE mark LIKE 'rpo-%'")
  record "rows lost from the last ${written}s of writes (RPO)" INFO "$((written - surviving)) of $written; archive_timeout is 60s"
  if wait_until 120 primary_fenced; then
    record "fenced pg-primary refuses connections" PASS
  else
    record "fenced pg-primary refuses connections" FAIL "still answering after 120s"
  fi
  # The fence must hold, not only take effect: nothing may lift it later.
  sleep 60
  if [[ $(kc -n "$NS" get cluster pg-primary -o jsonpath='{.metadata.annotations.cnpg\.io/fencedInstances}') == '["*"]' ]] &&
    primary_fenced; then
    record "fence still holds 60s later" PASS
  else
    record "fence still holds 60s later" FAIL "annotation removed or pg-primary answering again"
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
if [[ $MONITORING == 1 ]]; then install_monitoring; fi
deploy_object_store
deploy_databases
test_replication
test_restore_from_gcp_copy
test_kill_primary
test_object_store_outage
test_switchover
test_unplanned_failover
scenario=finished
