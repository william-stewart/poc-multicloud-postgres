# Deploy and operate

How to stand the system up on AWS and GCP, check it, move the primary between
clouds, and tear it down. The architecture and its trade-offs are in the
[README](../README.md).

## Deploy

The layers go up in this order. Each OpenTofu stack keeps its own state and finds the
layer below it by name, so the order matters in both directions.

| Step | What | Tool | Time |
| --- | --- | --- | --- |
| 1 | State backends (once) | `tofu apply` | 2 min |
| 2 | Networks | `tofu apply` | 3–5 min |
| 3 | Clusters | `tofu apply` | 12–15 min (EKS) |
| 4 | Platform: Cilium, the EKS nodes, CoreDNS, Flux, then Flux installs the rest | `make bootstrap` | 8–12 min |
| 5 | Archives: S3 and GCS buckets, IAM, Workload Identity Federation | `tofu apply` | 2–3 min |
| 6 | Credentials: the app owner on both clusters | `make app-credentials` | 1 min |
| 7 | Primary on EKS: network policies, then the database | `make data-vars` | 5 min + first backup |
| 8 | Replica on GKE: network policies, then the database | `make data-vars` | 5 min + first backup |

### Prerequisites

- An AWS account and a GCP project with billing, and admin credentials for both on your
  machine: `aws configure` (or SSO), `gcloud auth login` and
  `gcloud auth application-default login`.
- Tools: `tofu`, `aws` (v2), `gcloud` with `gke-gcloud-auth-plugin`, `kubectl`, `helm`,
  `flux`, `cilium`, `hubble`, the `kubectl cnpg` plugin and `gh`. Versions used for
  development are in `.tool-versions`. On macOS:

  ```sh
  brew install opentofu awscli kubectl helm fluxcd/tap/flux cilium-cli hubble kubectl-cnpg gh
  brew install --cask google-cloud-sdk
  gcloud components install gke-gcloud-auth-plugin
  gke-gcloud-auth-plugin --version   # must be on PATH: kubectl needs it for GKE
  ```
- Flux reads this private repo with a **read-only deploy key**. Create it once; the
  private half stays under `secrets/`, which is gitignored:

  ```sh
  ssh-keygen -t ed25519 -N '' -C flux -f secrets/flux-deploy-key
  gh repo deploy-key add secrets/flux-deploy-key.pub --title flux
  ```

- Flux syncs from `main`, so deploy from an up-to-date `main`.

Set these once per shell. The helpers configure each stack's remote backend from the
bootstrap outputs, so no account-specific values are committed:

```sh
export GCP_PROJECT=<your-gcp-project-id>
export MY_IP="$(curl -s https://checkip.amazonaws.com)/32"   # only this IP may reach the K8s APIs

aws_init() {
  tofu -chdir="infra/$1" init \
    -backend-config="bucket=$(tofu -chdir=infra/00-bootstrap/aws output -raw state_bucket)" \
    -backend-config="region=us-east-1" \
    -backend-config="kms_key_id=$(tofu -chdir=infra/00-bootstrap/aws output -raw state_kms_key_arn)"
}
gcp_init() {
  tofu -chdir="infra/$1" init \
    -backend-config="bucket=$(tofu -chdir=infra/00-bootstrap/gcp output -raw state_bucket)"
}
```

### 1. State backends (once)

```sh
tofu -chdir=infra/00-bootstrap/aws init && tofu -chdir=infra/00-bootstrap/aws apply
tofu -chdir=infra/00-bootstrap/gcp init && tofu -chdir=infra/00-bootstrap/gcp apply -var project_id="$GCP_PROJECT"
```

These two stacks keep their own state locally (gitignored) because they create the
remote backends; keep those files. They are never torn down: buckets and keys have
`prevent_destroy`, and the GKE Secrets key and the GCS WAL bucket's key live here
because Cloud KMS keys can never be deleted. If you set up the GCP stack before the WAL
key and the EKS Workload Identity pool existed, apply it again to add them.

### 2. Networks

```sh
aws_init 10-network/aws && tofu -chdir=infra/10-network/aws apply
gcp_init 10-network/gcp && tofu -chdir=infra/10-network/gcp apply -var project_id="$GCP_PROJECT"
```

### 3. Clusters

```sh
aws_init 20-clusters/aws && tofu -chdir=infra/20-clusters/aws apply -var "api_allowed_cidrs=[\"$MY_IP\"]"
gcp_init 20-clusters/gcp && tofu -chdir=infra/20-clusters/gcp apply \
  -var project_id="$GCP_PROJECT" -var "api_allowed_cidrs=[\"$MY_IP\"]"

eval "$(tofu -chdir=infra/20-clusters/aws output -raw kubeconfig_command)"   # context: poc-mcpg
eval "$(tofu -chdir=infra/20-clusters/gcp output -raw kubeconfig_command)"
export EKS=poc-mcpg
export GKE="$(kubectl config get-contexts -o name | grep '^gke_')"
```

The EKS node group is created with no nodes. Without a CNI they could never become
`Ready`, and EKS doesn't finish creating a node group until they are, so `make
bootstrap` adds them in the next step, once Cilium is installed. GKE's nodes come up
tainted, and run nothing until Cilium removes the taint.
Only the IAM principal that ran the apply is a cluster admin on EKS. If your IP
changes, re-apply with the new `MY_IP`.

### 4. Platform

```sh
make bootstrap CLOUD=aws CONTEXT="$EKS"
make bootstrap CLOUD=gcp CONTEXT="$GKE"
```

`make bootstrap` (`k8s/bootstrap.sh`) refuses to run against a cluster other than the
one the stack built. It then:

1. writes the cluster's account-specific values (API host, IAM role ARNs, DNS IP) from
   `tofu output` into the `flux-system/cluster-vars` ConfigMap
2. installs Cilium with Helm; on EKS it then scales the node group to `node_count`
   and waits for the nodes to register
3. waits for the Cilium agents, the operator and the nodes to be `Ready`; on EKS it
   then installs CoreDNS, because Flux can't resolve `github.com` without it, and
   restarts Hubble Relay and Hubble UI, which started before DNS worked
4. installs Flux with the deploy key and points it at `k8s/clusters/<cloud>`

Flux takes over the Cilium and CoreDNS releases (same versions and values files) and
installs cert-manager, the CloudNativePG operator, the Barman Cloud plugin and, on EKS,
the EBS CSI driver. Then it installs Prometheus and Grafana (`k8s/monitoring`) and the
PostgreSQL dashboard, which fills in once the databases exist (see
[Dashboard](#dashboard)).

```sh
flux --context "$EKS" get helmreleases -A          # all Ready
cilium --context "$EKS" status --wait
cilium --context "$GKE" status --wait
```

### 5. Archives in both clouds

```sh
aws_init 30-data/aws && tofu -chdir=infra/30-data/aws apply \
  -var "replica_egress_ips=$(tofu -chdir=infra/10-network/gcp output -json nat_egress_ips)" \
  -var gke_oidc_issuer_url="$(tofu -chdir=infra/20-clusters/gcp output -raw oidc_issuer_url)"
gcp_init 30-data/gcp && tofu -chdir=infra/30-data/gcp apply -var project_id="$GCP_PROJECT" \
  -var eks_oidc_issuer_url="$(tofu -chdir=infra/20-clusters/aws output -raw oidc_issuer_url)"
```

`infra/30-data/aws` creates the S3 bucket, `pg-primary`'s writer role (IRSA), and a
read-only role that `cnpg-db/pg-replica` assumes with a GKE service account token,
through an IAM OIDC provider that trusts the GKE cluster's issuer. `infra/30-data/gcp`
creates the GCS bucket, a Google service account that only `cnpg-db/pg-replica` can use
(Workload Identity), and a Workload Identity Federation provider that trusts the EKS
cluster's OIDC issuer, so `cnpg-db/pg-primary` can read the GCS bucket. Each stack
trusts the other cloud's cluster issuer, so no identity in either cloud has a
long-lived key. Both clusters need both archives: each one reads the other's to change
roles.

### 6. Credentials

```sh
make app-credentials EKS="$EKS" GKE="$GKE"
```

`make app-credentials` stores the same `app` owner credentials on both clusters, as
CloudNativePG requires for a distributed topology: `cnpg-db/app-owner`, which both
databases bootstrap with, and `app/postgres`, which clients in the `app` namespace
connect with (host `pg-primary-rw` on EKS, `pg-replica-rw` on GKE). The password is
generated once and goes straight into the Kubernetes API. Because it runs while both
clusters are up, GKE already holds the credentials if AWS is lost.

### 7. Primary on EKS

```sh
make data-vars CLOUD=aws CONTEXT="$EKS"
kubectl --context "$EKS" -n cnpg-db get cluster pg-primary -w   # until "Cluster in healthy state"
kubectl --context "$EKS" -n cnpg-db get backup -w               # until the first backup is completed
```

`make data-vars` stores the bucket names, region and writer role in the
`flux-system/data-vars` ConfigMap, and the GCS credential configuration (a token file
and a provider name, no key) in the `cnpg-db/gcs-reader` Secret. It refuses to run
until `make app-credentials` has. Flux applies nothing in `k8s/policies` or `k8s/data`
until the ConfigMap exists, so the database never starts with empty values. Flux then
applies the network policies first and the database only once they are ready, so no
database pod ever runs without default deny. Wait for `pg-primary` to be healthy and
its first backup to reach `completed`.

If a flow is missing from the policies, archiving or the backup stalls. Find the
dropped flow with Hubble rather than suspending the policies:

```sh
cilium --context "$EKS" hubble port-forward &
hubble observe -n cnpg-db --verdict DROPPED -f
```

### 8. Replica on GKE

```sh
make data-vars CLOUD=gcp CONTEXT="$GKE"
kubectl --context "$GKE" -n cnpg-db get cluster pg-replica -w
```

`make data-vars CLOUD=gcp` refuses to run until the primary's first base backup is in
S3, because the replica can't bootstrap without one.
Once the replica is ready it takes its first base backup to GCS; wait for it to reach
`completed` (`kubectl --context "$GKE" -n cnpg-db get backup`).

## Verify

```sh
# Cilium is the only CNI: no aws-node or kube-proxy on EKS, no anetd on GKE.
kubectl --context "$EKS" -n kube-system get daemonsets
kubectl --context "$GKE" -n kube-system get daemonsets | grep anetd   # no output

# Archiving and the base backup.
kubectl cnpg status pg-primary -n cnpg-db --context "$EKS"
aws s3 ls "s3://$(tofu -chdir=infra/30-data/aws output -raw wal_bucket)/pg-primary/"   # base/ and wals/

# End to end: a row written on AWS appears on GCP within about 1-2 minutes.
kubectl cnpg psql pg-primary -n cnpg-db --context "$EKS" -- -d app -c \
  "CREATE TABLE IF NOT EXISTS ping(ts timestamptz); INSERT INTO ping VALUES (now()); SELECT pg_switch_wal();"
kubectl cnpg psql pg-replica -n cnpg-db --context "$GKE" -- -d app -c \
  "SELECT max(ts) FROM ping; SELECT now() - pg_last_xact_replay_timestamp() AS lag;"

# The replica keeps its own copy in GCS: base/ and wals/ under pg-replica/.
gcloud storage ls "gs://$(tofu -chdir=infra/30-data/gcp output -raw wal_bucket)/pg-replica/"
kubectl cnpg status pg-replica -n cnpg-db --context "$GKE"   # WAL archiving OK, last backup

# The replica recovers from S3 after losing its pod.
kubectl --context "$GKE" -n cnpg-db delete pod pg-replica-1
kubectl cnpg status pg-replica -n cnpg-db --context "$GKE"

# Network policies: watch for drops while forcing a WAL switch and a backup.
hubble observe -n cnpg-db --verdict DROPPED -f
# The same flows as a live service map, allowed and dropped (Hubble UI, opens a browser):
cilium --context "$EKS" hubble ui
# No access from other namespaces (times out):
kubectl --context "$EKS" run nettest --rm -it --restart=Never -n default --image=postgres:18 -- \
  pg_isready -h pg-primary-rw.cnpg-db -t 5
# No internet from the database (fails):
kubectl --context "$EKS" -n cnpg-db exec pg-primary-1 -c postgres -- timeout 5 bash -c '</dev/tcp/example.com/443'
# The app namespace can reach the primary (accepting connections), on both sides;
# on GKE it is read-only until pg-replica is promoted:
kubectl --context "$EKS" run nettest --rm -it --restart=Never -n app --image=postgres:18 -- \
  pg_isready -h pg-primary-rw.cnpg-db -t 5
kubectl --context "$GKE" run nettest --rm -it --restart=Never -n app --image=postgres:18 -- \
  pg_isready -h pg-replica-rw.cnpg-db -t 5
```

### Dashboard

Flux runs Prometheus and Grafana on each cluster, with the same chart, values and
dashboard as `make e2e`. Each Grafana shows its own cluster's Cluster: `pg-primary`
on EKS, `pg-replica` on GKE. There is no network path between the clouds, so open
both side by side to see the whole topology:

```sh
make grafana CONTEXT="$EKS"              # http://localhost:3000/d/postgres-dr
make grafana CONTEXT="$GKE" PORT=3001    # in another terminal: http://localhost:3001/d/postgres-dr
```

Grafana opens read-only without a login, and only through the port-forward; the admin
password is in the `monitoring/kube-prometheus-stack-grafana` Secret. Prometheus keeps
two days of data, on an emptyDir volume, so a restart of its pod loses it. Prometheus
reaches the instances' metrics port through
[`allow-prometheus-scrape`](../k8s/policies/base/allow-prometheus-scrape.yaml); without
it, default deny drops every scrape.

## Automated drill

`make live-drill` runs the non-destructive drills against both clusters and
records the results in `evidence/live/<UTC time>.md`. It takes about 20-30
minutes and ends where it started, so it can run any number of times:

```sh
make live-drill EKS="$EKS" GKE="$GKE"
```

1. Replication: a row written on `pg-primary` reaches `pg-replica` through S3, and
   `pg-replica` archives it again to GCS.
2. Kill the primary pod on EKS: the other instance takes writes and nothing is lost.
3. Lose `pg-replica`'s pod on GKE: it comes back and resumes from S3.
4. Planned switchover to GCP and back: no row lost, replication both ways.

It refuses to run unless both contexts are the clusters the stacks built and the
roles match git. It suspends Flux's `data` layer on both clusters and makes the
role changes with `kubectl patch`, so nothing is committed or pushed; the
git-to-Flux step is what the manual switchover below exercises. When the roles
are back where git has them, it resumes Flux. If a run fails while the roles are
swapped, Flux stays suspended and the script prints the current state: finish or
reverse the switchover by hand, then `flux resume kustomization data` on each
cluster. Diagnostics from a failed run go to `test/live/results/` (gitignored).
The unplanned failover isn't included, because it needs the failback below.

## Switchover, failover and failback

`pg-primary` and `pg-replica` are the two members of one CloudNativePG
[distributed topology](https://cloudnative-pg.io/docs/current/replica_cluster). Each
`Cluster` lists both members in `externalClusters`, read through their archives, and
`spec.replica.primary` names the one primary. Every role change is a commit to
`replica.primary` in `k8s/data/aws/cluster.yaml` and `k8s/data/gcp/cluster.yaml`, which
Flux applies. `make validate` rejects any commit in which both name themselves the
primary, unless one of them is fenced in full (see
[Unplanned failover](#unplanned-failover-aws-is-lost)).

This replaces the plain `replica.enabled: false` promotion: with it, the operator
demotes the old primary cleanly and hands over a promotion token, so a planned
switchover loses nothing and needs no rebuild.

### Planned switchover to GCP

No data is lost. Writes are refused from step 1 until step 2 completes.

1. **Demote `pg-primary`.** Commit `replica.primary: pg-replica` in
   `k8s/data/aws/cluster.yaml` only, and let Flux apply it
   (`flux --context "$EKS" reconcile kustomization data --with-source`). `pg-primary`
   stops accepting writes, archives its last WAL to S3 and publishes a demotion token:

   ```sh
   kubectl --context "$EKS" -n cnpg-db get cluster pg-primary -o jsonpath='{.status.demotionToken}'
   ```

2. **Promote `pg-replica`.** In one commit to `k8s/data/gcp/cluster.yaml`, set
   `replica.primary: pg-replica` and `replica.promotionToken: <token>` together. The
   token isn't a secret: it holds the system identifier, timeline and checkpoint
   location. `pg-replica` replays up to that point, then promotes and starts a new
   timeline in GCS. `pg-primary` follows it from GCS.

3. **Move clients** to the `app` namespace on GKE. They connect with the `app/postgres`
   Secret already there.

Switching back is the same with the roles reversed. The validator makes you remove the
old `promotionToken` in the commit that demotes `pg-replica` again.

### Unplanned failover: AWS is lost

1. **Promote `pg-replica` and fence `pg-primary`, in one commit:**
   - `k8s/data/gcp/cluster.yaml`: `replica.primary: pg-replica`, with no token. It
     promotes at once, at the last WAL it replayed.
   - `k8s/data/aws/cluster.yaml`: only the annotation
     `cnpg.io/fencedInstances: '["*"]'` on `pg-primary`. Leave `replica.primary`
     as it is: demoting `pg-primary` restarts it, and CloudNativePG lifts the fence
     during that restart (`make e2e` showed it). `make validate` accepts both
     clusters naming themselves the primary only while one is fenced in full.

2. **Move clients** to the `app` namespace on GKE, as above.

**Data lost:** what `pg-primary` wrote after the last WAL `pg-replica` fetched. That's
up to `archive_timeout` (60s) plus however far the replica was behind.

**Fencing.** When EKS comes back, Flux's first reconcile applies the fence, and
CloudNativePG stops PostgreSQL in every `pg-primary` instance: it accepts no
connections and archives nothing more. Demotion wouldn't help, because a primary
that was failed over without a token has diverged and can't follow the new one, and
it lifts the fence.
What this doesn't cover is the gap between EKS returning and Flux reconciling: the old
instances can start as primary for that window. Anything written then is lost, but it
only ever reaches `pg-primary/` in S3, never `pg-replica`'s archive, so the new
timeline can't be contaminated. Closing that gap needs a fence that doesn't depend on
the old cluster, such as cutting its clients off at the network or a witness. That's
listed under Known gaps.

### Failback to AWS after a failover

The fenced `pg-primary` has diverged, so it's rebuilt from `pg-replica`'s GCS archive,
then switched back with a planned switchover:

```sh
# 1. Keep Flux from recreating pg-primary from the old spec.
flux --context "$EKS" suspend kustomization data

# 2. Delete the old cluster, its claims and their retained volumes.
kubectl --context "$EKS" -n cnpg-db delete cluster pg-primary
kubectl --context "$EKS" -n cnpg-db delete pvc -l cnpg.io/cluster=pg-primary
kubectl --context "$EKS" get pv   # delete the Released pg-primary volumes

# 3. Set the old archive aside: Barman won't archive into a prefix that holds
#    another history. The writer role can't touch the new prefix.
bucket=$(tofu -chdir=infra/30-data/aws output -raw wal_bucket)
aws s3 mv --recursive "s3://$bucket/pg-primary/" "s3://$bucket/pg-primary-diverged-$(date +%Y%m%d)/"
```

4. Commit to `k8s/data/aws/cluster.yaml`: replace `bootstrap.initdb` with
   `bootstrap.recovery` from `pg-replica` (same `database`, `owner` and `secret`),
   remove the fence annotation, and set `replica.primary: pg-replica`.
5. `flux --context "$EKS" resume kustomization data`. `pg-primary` is recreated from
   GCS as a replica of `pg-replica`.
6. Once it has caught up, run a planned switchover back to AWS. Then restore
   `bootstrap.initdb` in git, so a fresh build still starts from an empty database.

Losing GCP while AWS is the primary is the mirror image: rebuild `pg-replica` from S3,
after setting `gs://<bucket>/pg-replica/` aside.

**Client cutover stops at the cluster boundary.** Applications in the `app` namespace
on either cluster reach their local primary through the `<cluster>-rw` Service.
Routing clients outside the clusters (a DNS name that follows the primary, or global
traffic management) is out of scope for a database PoC. It would take a DNS record
switched in the same commit (for example with external-dns), and each `-rw` Service
exposed through an internal load balancer on the clients' network.

## Tear down

Tear down in reverse. The order is required, not just tidy:

- Each stack looks up the one below it, so `30-data` must go before `20-clusters`, and
  `20-clusters` before `10-network`.
- The database StorageClasses keep their volumes (`reclaimPolicy: Retain`), so that no
  mistake deletes data. Tearing down is the one time you want the volumes gone: switch
  them to `Delete` first, or the EBS and Persistent Disk volumes stay behind, still
  billed.

```sh
# 1. Stop Flux from recreating anything, mark the database volumes for deletion,
#    then delete the databases (and with them their volumes).
for ctx in "$EKS" "$GKE"; do
  flux --context "$ctx" suspend kustomization --all
  kubectl --context "$ctx" get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="cnpg-db")]}{.metadata.name}{"\n"}{end}' |
    while read -r pv; do
      kubectl --context "$ctx" patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
    done
done
kubectl --context "$GKE" -n cnpg-db delete cluster pg-replica
kubectl --context "$EKS" -n cnpg-db delete cluster pg-primary
kubectl --context "$EKS" get pv; kubectl --context "$GKE" get pv   # wait until empty

# 2. Cloud resources, top layer first. 30-data empties the buckets and removes
#    the cross-cloud trust (the IAM OIDC provider and the GCP federation provider).
tofu -chdir=infra/30-data/gcp destroy -var project_id="$GCP_PROJECT" \
  -var eks_oidc_issuer_url="$(tofu -chdir=infra/20-clusters/aws output -raw oidc_issuer_url)"
tofu -chdir=infra/30-data/aws destroy \
  -var "replica_egress_ips=$(tofu -chdir=infra/10-network/gcp output -json nat_egress_ips)" \
  -var gke_oidc_issuer_url="$(tofu -chdir=infra/20-clusters/gcp output -raw oidc_issuer_url)"
tofu -chdir=infra/20-clusters/gcp destroy -var project_id="$GCP_PROJECT" -var "api_allowed_cidrs=[\"$MY_IP\"]"
tofu -chdir=infra/20-clusters/aws destroy -var "api_allowed_cidrs=[\"$MY_IP\"]"
make cilium-enis            # lists ENIs Cilium left in the VPC; DELETE=1 removes them
tofu -chdir=infra/10-network/gcp destroy -var project_id="$GCP_PROJECT"
tofu -chdir=infra/10-network/aws destroy
```

The state backends stay. In ENI mode the Cilium operator creates ENIs and
garbage-collects the unattached ones every 5 minutes, but once the cluster is gone
nothing does, and a leftover ENI blocks the VPC's destroy. `make cilium-enis` lists
the unattached ENIs in this VPC tagged `io.cilium/cilium-managed=true`, and with
`DELETE=1` deletes exactly those. When you're done with the project for good, also remove the deploy key
(`gh repo deploy-key delete`) and `secrets/flux-deploy-key*`.
