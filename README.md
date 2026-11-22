# poc-multicloud-postgres

Disaster recovery for PostgreSQL across two clouds. A primary on AWS (EKS) archives
its WAL to S3, and a replica on Google Cloud (GKE) replays it from there and keeps its
own backups in GCS, so either cloud can restore on its own, and either can become the
primary through a commit to git. Both clusters are hardened: nodes run
container-optimized OSes (Bottlerocket, Container-Optimized OS) with no public IPs,
default-deny network policies allow only named flows and hostnames, and no identity
holds a long-lived cloud key. Flux reconciles everything inside them from this repo.

![pg-primary on AWS writes WAL and backups to S3; pg-replica on GCP reads them from S3
and writes its own to GCS, which pg-primary reads after a switchover](docs/high_level.png)

[Diagram source](docs/architecture.md)

The clouds share no network: WAL travels through object storage, with no VPN or inbound
path between them, at the cost of lag. While healthy, the replica trails by up to
`archive_timeout` (60s), so an unplanned failover loses about a minute of writes; if
the primary can't reach S3, the lag grows for as long as the outage lasts.

## Testing failure scenarios

`make e2e` runs the real manifests on a local cluster, then kills the primary pod, takes
the object store away, switches over and back, and fails over with the old primary
fenced. Every run is recorded in [`evidence/e2e`](evidence/e2e).

![The dashboard over a full end-to-end run: the roles swap during the switchover and
back, pg-primary ends fenced, and WAL waits for the archive through the object store
outage](evidence/e2e_grafana.png)

*One run ([results](evidence/e2e/20261122T003509Z.md)), scenarios between dashed lines:
the roles swap and swap back, WAL waits for the archive during the outage, and
`pg-primary` ends fenced after the failover.*

| Guide | What's in it |
| --- | --- |
| [Deploy and operate](docs/deploy.md) | Standing it up on AWS and GCP, verifying it, switchover, failover, failback, tear down |
| [End-to-end test](docs/e2e.md) | The local test's scenarios, what it doesn't prove, and watching it in Grafana |

## Design

**Kubernetes is the portability layer.** OpenTofu manages cloud primitives only
(networks, NAT, clusters, buckets, IAM) and has no Helm or Kubernetes providers; a
pre-commit hook enforces that. Everything inside the clusters is Helm and kustomize,
reconciled by Flux, and nearly identical on both clouds.

**Archive-only replication.** The replica follows the primary through the S3 WAL
archive, with an RPO of about `archive_timeout` (60s). In exchange there's no VPN, no
inbound path between the clouds and little to operate. Streaming replication over an
HA VPN is the upgrade path if lag must be lower.

**An independent copy of the backups in each cloud.** `pg-primary` archives to S3
in `us-east-1`. `pg-replica` replays from there and, as a CloudNativePG replica cluster,
runs with `archive_mode=always`: every WAL segment it replays is archived again to its
own GCS bucket in `us-central1`, and it takes its own nightly base backups there. The
GCS copy is written by a GCP identity, with a GCP key, under `pg-replica/`, so nothing
on the GCP side needs AWS to recover, and a promoted replica keeps archiving to the
same place without a change. The cost is a second archive (about 1,440 WAL segments a
day at `archive_timeout` 60s, gzip-compressed) and a second base backup.

What still works when one cloud is lost:

| Lost | Data | Still works | What's lost or degraded |
| --- | --- | --- | --- |
| AWS `us-east-1` | GCS holds `pg-replica`'s base backups and every WAL segment it replayed | Fail over to `pg-replica` (see [Unplanned failover](docs/deploy.md#unplanned-failover-aws-is-lost)); it keeps archiving to GCS and taking backups, so it has PITR from the first GCS base backup on, and serves clients in GKE's `app` namespace. If its volume is also lost, a new cluster can be restored from GCS | Writes since the last WAL the replica replayed: up to `archive_timeout` (60s), plus anything S3 held that the replica hadn't fetched yet. Applications on EKS |
| GCP `us-central1` | S3 holds `pg-primary`'s base backups and WAL | The primary, its archive and its backups are unaffected | The DR copy and the GCS backups. Rebuild the replica from S3 ([step 8](docs/deploy.md#8-replica-on-gke)) once GCP is back |
| Only one Kubernetes cluster | Both buckets | The other side as above; the lost side is rebuilt from its own bucket or the other cloud's | |

Two limits of this design. The GCS copy can only be as current as the replica: if the
replica stops replaying, the GCS archive stops too, so replication lag is also the age
of the GCP backups. And Barman won't archive into a prefix that already holds another
cluster's history, so a cluster restored from GCS must archive under a new name (a
different `serverName`, or a new bucket), never back into `pg-replica/` or `pg-primary/`.

**Shared settings and module interfaces.** `infra/modules/settings` holds the values
both clouds share (names, regions, zones, address plan, Kubernetes version, node OS,
labels), and validation rejects overlapping address ranges. Each cloud has its own
module per concern (`network`, `network-lookup`, `cluster`) rather than one module with
a `cloud` switch, so each stack needs one provider and one set of credentials. OpenTofu
has no way to declare a module interface, so two checks keep the AWS and GCP modules
interchangeable for callers: `scripts/check_module_contracts.py` checks that the inputs
and outputs in each `contract.json` are declared, and `infra/tests/contracts` checks the
values the outputs produce.

**Separate state per layer, joined by data sources.** Later stacks find the layers
below them by name (`network-lookup`, EKS and KMS data sources), not through
`terraform_remote_state`, so a stack needs only read access in the cloud, never another
stack's state file.

## Repository layout

| Path | Contents |
| --- | --- |
| `infra/modules/settings` | Values both clouds share |
| `infra/modules/{network,network-lookup,cluster}/{aws,gcp}` | One module per cloud behind a shared `contract.json` |
| `infra/00-bootstrap/{aws,gcp}` | State buckets and long-lived KMS keys |
| `infra/10-network/{aws,gcp}` | VPCs, subnets, NAT, S3 gateway endpoint, firewall |
| `infra/20-clusters/{aws,gcp}` | EKS and GKE without a default CNI; IRSA roles |
| `infra/30-data/aws` | S3 WAL bucket, KMS key, writer role, and the GKE reader role through an IAM OIDC provider |
| `infra/30-data/gcp` | GCS WAL bucket for the replica's own archive, its Workload Identity writer, and the EKS reader through Workload Identity Federation |
| `infra/tests/contracts` | Contract tests for the per-cloud modules |
| `k8s/flux` | Flux controllers (generated, images pinned by digest) |
| `k8s/clusters/{aws,gcp}` | Each cluster's Flux entry point and `*.example.env` variable lists |
| `k8s/platform` | Cilium, CoreDNS, cert-manager, CloudNativePG, Barman plugin, EBS CSI |
| `k8s/data` | The PostgreSQL clusters, object stores and backups |
| `k8s/policies` | Default deny and Cilium allow rules for `cnpg-db` |
| `k8s/monitoring` | Prometheus, Grafana, the PodMonitor and the PostgreSQL dashboard (Flux on both clusters, and `make e2e`) |
| `k8s/*.sh` | `bootstrap.sh`, `data-vars.sh`, `app-credentials.sh` (run through `make`) |
| `test/e2e` | The local end-to-end test (`make e2e`) and its overlays of `k8s/data` |
| `docs` | Deploy and operate runbook, end-to-end test guide |
| `evidence/e2e` | Results of end-to-end runs |

## Local validation

```sh
brew install opentofu trivy gitleaks pre-commit checkov helm kustomize kubeconform shellcheck
brew install terraform-linters/tap/tflint fluxcd/tap/flux
make hooks      # pre-commit and commit-msg hooks
make validate   # every check below; no cloud credentials needed
```

`make validate` runs, without touching any cloud API or state backend:

1. `tofu fmt`, `tofu validate` and `tofu test` (mock providers) in every stack and module
2. pre-commit: gitleaks, checkov, trivy and tflint for OpenTofu, shellcheck, file
   hygiene, and project guardrails (no `aws_iam_access_key`, no in-cluster providers in
   OpenTofu, module contracts)
3. the Kubernetes layer (`scripts/validate_k8s.py`), for every Flux layer of each cluster:
   - kustomize builds validated with kubeconform against Kubernetes 1.36 and strict
     schemas generated from the CRDs that Flux, the pinned charts and Cilium install
   - `helm template` of every `HelmRelease` at its pinned version, and every values key
     checked against the chart's schema
   - checkov's Kubernetes checks on the manifests exactly as Flux applies them
   - `${VARS}` checked against the `*.example.env` files, and `bootstrap.sh` and the Flux
     image digests checked against what Flux manages
   - the end-to-end test's overlays rendered and validated the same way
4. `gitleaks` over the full git history

CI runs `make validate` on every pull request and on pushes to `main`, with a read-only
token and no cloud credentials.

**Least privilege.**

| Identity | Can | Only |
| --- | --- | --- |
| WAL writer (IRSA, `cnpg-db/pg-primary`) | List, read, write, delete | `pg-primary/`, through the VPC's S3 gateway endpoint; the KMS key through S3 |
| WAL reader (IAM role, `cnpg-db/pg-replica` on GKE through its OIDC issuer) | List, read | `pg-primary/`, from the GCP Cloud NAT IP; decrypt through S3; only tokens with the `sts.amazonaws.com` audience |
| GCS WAL writer (Workload Identity, `cnpg-db/pg-replica`) | List, read, write, delete objects; read bucket metadata | The GCS WAL bucket; no project-level roles |
| GCS WAL reader (Workload Identity Federation, `cnpg-db/pg-primary` on EKS) | List, read objects; read bucket metadata | The GCS WAL bucket; only tokens from this EKS cluster's issuer for this service account |
| Cilium operator (IRSA) | The ENI calls in Cilium's docs | This account and region |
| EBS CSI driver (IRSA) | AWS's EBS CSI policy | |

Kubernetes Secrets are encrypted with customer-managed KMS keys on both clouds. The
public API endpoints accept only `api_allowed_cidrs`, nodes have no public IPs, and nodes run
hardened container OSes (Bottlerocket with no SSH or SSM and kernel lockdown;
Container-Optimized OS with Shielded VM). No identity has a long-lived key: every
credential is a service account token exchanged for short-lived cloud credentials,
within its own cloud (IRSA, GKE Workload Identity) or across (an IAM OIDC provider for
GKE's issuer, GCP Workload Identity Federation for EKS's). A pre-commit hook rejects
`aws_iam_access_key` in OpenTofu.

## Known gaps and next steps

- HA VPN and streaming replication, for lag under a minute.
- A fence that doesn't depend on the old primary's cluster reconciling first, and
  client routing across clouds (DNS that follows the primary).
- One Grafana across both clouds (both Prometheus servers writing to a shared or hosted
  one), persistent Prometheus storage, and alerts on archive failures and replica
  lag; regional, multi-AZ clusters; one NAT gateway per AZ.
