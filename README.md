# poc-multicloud-postgres

PostgreSQL disaster recovery across AWS and Google Cloud, run by the CloudNativePG
(CNPG) operator. A primary on EKS archives its WAL to S3; a CNPG replica cluster on GKE
replays it and keeps its own backups in GCS. Either cloud can restore on its own, and
either can become the primary through a commit to git.

![pg-primary on AWS writes WAL and backups to S3; pg-replica on GCP reads them from S3
and writes its own to GCS, which pg-primary reads after a switchover](docs/high_level.png)

**Database:** PostgreSQL 18 • CloudNativePG • Barman Cloud plugin\
**Infrastructure:** OpenTofu • EKS (Bottlerocket) • GKE (Container-Optimized OS) • S3 • GCS\
**In-cluster:** Flux • Helm • Cilium • Prometheus • Grafana

- **RPO of about 60s** (`archive_timeout`) while healthy, with no network path between
  the clouds.
- **No long-lived cloud keys.** Every credential is a Kubernetes service account token
  exchanged for short-lived cloud credentials, within each cloud and across them.
- **Failure scenarios tested.** `make e2e` kills the primary, takes the object store
  away, switches over and back, and fails over. Every run is recorded.
- **Validated without credentials.** `make validate` (linters, policy scans, mock
  `tofu test`, schema-checked manifests) runs in CI on every pull request.

## Trade-offs

| Decision | Gain | Cost |
| --- | --- | --- |
| Replicate through the WAL archive, not streaming over a VPN | No VPN, no inbound path between the clouds, little to operate | The replica trails by up to 60s, so an unplanned failover loses about a minute of writes; if the primary can't reach S3, lag grows for as long as the outage lasts |
| The replica archives again to its own GCS bucket (`archive_mode=always`) | GCP recovers without AWS; a promoted replica keeps archiving with no change | A second archive and base backup to pay for; the GCS copy is only as current as the replica |
| Self-managed Cilium as the only CNI on both clouds, not the VPC CNI and Dataplane V2 | One policy model with FQDN egress rules (S3, STS, GCS) and the same datapath and Hubble on both clouds, tested once | A bootstrap step before Flux; the admin is responsible for Cilium upgrades, which cap the Kubernetes version, and for CNI problems the provider won't fix; leftover ENIs at teardown |
| Kubernetes as the portability layer: OpenTofu for cloud primitives only, Flux for everything in the clusters | The in-cluster layer is nearly identical on both clouds | The admin is responsible for CoreDNS, the EBS CSI driver and the CNI, not managed add-ons |
| One module per cloud behind a shared `contract.json`, not one module with a `cloud` switch | Each stack needs one provider and one set of credentials | OpenTofu has no module interfaces, so a script and contract tests keep the modules interchangeable |
| Separate state per layer, joined by data sources, not `terraform_remote_state` | A stack needs read access in the cloud, never another stack's state | Stacks find each other by name, so names live in one shared settings module |
| Zonal GKE and a single NAT gateway on AWS | Lower cost for a PoC (GKE's zonal control plane is free) | Not production HA (see [Known gaps](#known-gaps-and-next-steps)) |

More detail: [design notes](docs/design.md).

## Losing a cloud

| Lost | Recovery | Lost or degraded |
| --- | --- | --- |
| AWS `us-east-1` | [Fail over](docs/deploy.md#unplanned-failover-aws-is-lost) to `pg-replica`, which keeps archiving and backing up to GCS and serves GKE's `app` namespace | Writes the replica hadn't replayed (up to 60s, plus anything in S3 it hadn't fetched); applications on EKS |
| GCP `us-central1` | Nothing to do: the primary, its archive and its backups are unaffected | The DR copy, until the replica is [rebuilt from S3](docs/deploy.md#8-replica-on-gke) |
| One Kubernetes cluster | Rebuild it from its own bucket or the other cloud's | |

## Tested failure scenarios

`make e2e` runs the real manifests on a local cluster and breaks them on purpose. Cloud
identities and Cilium policies are emulated there; everything else is what production
runs ([what it does and doesn't prove](docs/e2e.md)).

![The dashboard over a full end-to-end run: the roles swap during the switchover and
back, pg-primary ends fenced, and WAL waits for the archive through the object store
outage](evidence/e2e_grafana.png)

*One run ([results](evidence/e2e/20261122T003509Z.md)), scenarios between dashed lines:
the roles swap and swap back, WAL waits for the archive during the outage, and
`pg-primary` ends fenced after the failover. [All runs](evidence/e2e).*

The same scenarios, minus the destructive ones, also ran on real EKS and GKE clusters
([screenshots and results](evidence/live)).

## Security

| Identity | Can | Only |
| --- | --- | --- |
| WAL writer (IRSA, `cnpg-db/pg-primary`) | List, read, write, delete | `pg-primary/`, through the VPC's S3 gateway endpoint; the KMS key through S3 |
| WAL reader (IAM role, `cnpg-db/pg-replica` on GKE through its OIDC issuer) | List, read | `pg-primary/`, from the GCP Cloud NAT IP; decrypt through S3; only tokens with the `sts.amazonaws.com` audience |
| GCS WAL writer (Workload Identity, `cnpg-db/pg-replica`) | List, read, write, delete objects; read bucket metadata | The GCS WAL bucket; no project-level roles |
| GCS WAL reader (Workload Identity Federation, `cnpg-db/pg-primary` on EKS) | List, read objects; read bucket metadata | The GCS WAL bucket; only tokens from this EKS cluster's issuer for this service account |
| Cilium operator (IRSA) | The ENI calls in Cilium's docs | This account and region |
| EBS CSI driver (IRSA) | AWS's EBS CSI policy | |

- **No stored keys.** IRSA and GKE Workload Identity within each cloud; across clouds,
  AWS IAM trusts GKE's OIDC issuer and GCP Workload Identity Federation trusts EKS's,
  each for one service account ([how](docs/design.md#cross-cloud-identity)). A
  pre-commit hook rejects `aws_iam_access_key`.
- **Default deny** in `cnpg-db`; Cilium rules allow only named flows and hostnames.
- **Hardened nodes** with no public IPs: Bottlerocket (no SSH or SSM, kernel lockdown)
  and Container-Optimized OS with Shielded VM. The API endpoints accept only
  `api_allowed_cidrs`.
- **Kubernetes Secrets** encrypted with customer-managed KMS keys on both clouds.

## Run it

```sh
make validate   # every local check; no cloud credentials needed
make e2e        # failure scenarios on a local cluster, about 20-30 minutes
make live-drill EKS=<context> GKE=<context>   # switchover and back on the live clusters
```

| Guide | What's in it |
| --- | --- |
| [Deploy and operate](docs/deploy.md) | Standing it up on AWS and GCP, verifying it, switchover, failover, failback, tear down |
| [End-to-end test](docs/e2e.md) | The local test's scenarios, what it doesn't prove, and watching it in Grafana |
| [Design notes](docs/design.md) | Cross-cloud identity, the second archive and its limits, module interfaces, state |
| [Development](docs/development.md) | Tools, what `make validate` checks, repository layout |

## Known gaps and next steps

- HA VPN and streaming replication, for lag under a minute.
- A fence that doesn't depend on the old primary's cluster reconciling first, and
  client routing across clouds (DNS that follows the primary).
- One Grafana across both clouds (both Prometheus servers writing to a shared or hosted
  one), persistent Prometheus storage, and alerts on archive failures and replica
  lag; regional, multi-AZ clusters; one NAT gateway per AZ.
