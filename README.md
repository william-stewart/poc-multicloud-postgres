# poc-multicloud-postgres

A proof of concept for running CloudNativePG across clouds: a primary cluster on
EKS archives WAL to S3, and a replica cluster on GKE replays it. Both clusters
run Cilium as the only CNI, with default-deny network policies.

## Layout

| Path | Tool | Contents |
| --- | --- | --- |
| `infra/modules/settings` | OpenTofu | Values both clouds share: names, regions, zones, address plan, labels |
| `infra/modules/network/{aws,gcp}` | OpenTofu | One network module per cloud behind a shared interface |
| `infra/modules/network-lookup/{aws,gcp}` | OpenTofu | Read-only lookups of those networks, for stacks that keep their own state |
| `infra/modules/cluster/{aws,gcp}` | OpenTofu | One Kubernetes cluster module per cloud behind a shared interface |
| `infra/tests/contracts` | OpenTofu (`tofu test`) | Contract tests that run every per-cloud implementation against mocks |
| `infra/00-bootstrap/{aws,gcp}` | OpenTofu | Remote state buckets (S3 with native locking, GCS) |
| `infra/10-network/{aws,gcp}` | OpenTofu | VPCs, subnets, NAT, S3 gateway endpoint |
| `infra/20-clusters/{aws,gcp}` | OpenTofu | EKS and GKE without a default CNI |
| `infra/30-data/aws` | OpenTofu | WAL bucket, KMS key, IRSA writer role, read-only replica user |
| `k8s/flux` | Flux | Flux controllers and CRDs, the same on both clusters |
| `k8s/clusters/{aws,gcp}` | Flux + kustomize | Per-cluster entry point: Git sync and the platform Kustomization |
| `k8s/platform/{base,aws,gcp}` | Flux `HelmRelease` + kustomize | Cilium, CoreDNS (EKS), cert-manager, CloudNativePG, Barman Cloud plugin, EBS CSI driver (EKS) |
| `k8s/data/{base,aws,gcp}` | Flux + kustomize | The PostgreSQL clusters, their object stores and backups |
| `k8s/policies/{base,aws,gcp}` | Flux + kustomize | Default-deny network policies for `cnpg-db`, plus Cilium allow rules |

OpenTofu manages cloud primitives only. It has no Helm or Kubernetes providers,
and a pre-commit hook enforces that. Everything inside the clusters is reconciled
from this repo by Flux.

## Shared settings and module interfaces

Two patterns keep the clouds consistent without hiding their differences.

**One settings module.** `infra/modules/settings` has no providers and no
resources. It returns the values both clouds must agree on: the name prefix,
regions, zones, address plan, Kubernetes version, node count and node OS, and base
labels. Every stack calls it, so each value is defined once. Validation rejects
address ranges that overlap, fall outside `10.0.0.0/8`, or have host bits set.

**Matching interfaces, separate implementations.** Each cloud has its own module
(`infra/modules/network/aws`, `.../gcp`), and each stack picks the one for its
cloud. There is no `cloud = "aws"` switch inside a module. Each pair declares the
inputs and outputs listed in its `contract.json`:

| Contract | Inputs | Outputs |
| --- | --- | --- |
| `modules/network` | `name`, `region`, `cidr`, `labels` | `network_id`, `network_name`, `private_subnet_ids`, `nat_egress_ips` |
| `modules/network-lookup` | `name`, `region` | the same four as `network` |
| `modules/cluster` | `name`, `kubernetes_version`, `node_count`, `machine_type`, `node_image`, `api_allowed_cidrs`, `labels` | `cluster_name`, `cluster_endpoint`, `cluster_ca_certificate`, `oidc_issuer_url`, `kubeconfig_command` |

Features that exist on only one cloud stay as extra inputs and outputs on that
module: for example AWS zone IDs, the S3 gateway endpoint and IRSA roles, or GCP
secondary ranges and the Secrets encryption key.

OpenTofu has no way to declare a module interface, so two checks were added to
enforce it. They keep the AWS and GCP implementations interchangeable from a
caller's point of view: a stack can use either cloud's outputs, or swap a module
for its lookup, without changing how those outputs are consumed. Each check catches
what the other can't:

| Check | What it verifies | How |
| --- | --- | --- |
| `scripts/check_module_contracts.py` (pre-commit hook) | Every contract input and output is **declared**, and input types match | Reads the `.tf` files; no providers needed |
| `infra/tests/contracts` (`tofu test`) | The outputs' **values** have the contracted shape, for example `private_subnet_ids` a list (not a tuple) of strings, `nat_egress_ips` a list of IPv4 addresses, `cluster_endpoint` an `https://` URL | Runs each implementation against mock providers |

Separate implementations keep each stack to one provider and one set of
credentials, and keep the differences between clouds visible in review. The
portability layer is Kubernetes, not OpenTofu.

## Separate state per layer

Networks and clusters keep separate state, so applying a cluster change can't
touch the network, and each layer can use its own, narrower IAM role.

Later stacks find the network through **data sources, not
`terraform_remote_state`**. `infra/modules/network-lookup/{aws,gcp}` look the
network up by the names from the settings module (on AWS, the VPC `Name` tag and a
`tier` subnet tag). They return the same four shared outputs as the network modules
(their own `contract.json`). A stack that only needs subnet IDs therefore needs read
access in the cloud, but no access to another stack's state file, and isn't tied to
where that state lives. Tests on both sides pin the GCP naming convention, so a
rename can't quietly break a lookup.

OpenTofu can't see dependencies between states, so the teardown order matters:
Kubernetes layer first, then `20-clusters`, then `10-network`. Destroying a
network while a cluster still exists hangs on the ENIs, load balancers and
firewall rules that the cluster created.

## Address plan

The ranges don't overlap, so a VPN and streaming replication can be added later.
They are defined in `infra/modules/settings`.

| Network | CIDR |
| --- | --- |
| AWS VPC | `10.10.0.0/16` |
| GCP subnet (nodes) | `10.20.0.0/20` |
| GKE pods (secondary range) | `10.21.0.0/16` |
| GKE services (secondary range) | `10.22.0.0/20` |

## State backends (`infra/00-bootstrap`)

Each cloud gets its own bootstrap stack, so neither needs the other cloud's
credentials. The stacks keep their own state locally (gitignored), because they
create the remote backends everything else uses. That state holds only bucket
and key identifiers.

| | AWS | GCP |
| --- | --- | --- |
| Bucket | S3, versioned, public access blocked, ACLs disabled, TLS 1.2+ enforced by policy | GCS, versioned, public access prevention enforced, uniform bucket-level access |
| Encryption | Customer-managed KMS key with rotation | Customer-managed Cloud KMS key, 90-day rotation |
| Locking | S3-native lock file (`use_lockfile`), so no DynamoDB table | Built into the GCS backend |
| Retention | Old state versions expire after 90 days | Old state versions are deleted after 90 days |

Buckets and keys have `prevent_destroy`, so a stray `tofu destroy` can't take
the state with them.

```sh
tofu -chdir=infra/00-bootstrap/aws init && tofu -chdir=infra/00-bootstrap/aws apply
tofu -chdir=infra/00-bootstrap/gcp init && tofu -chdir=infra/00-bootstrap/gcp apply -var project_id=<project>
tofu -chdir=infra/00-bootstrap/aws output backend_config   # values for later stacks
```

## Networks (`infra/10-network`)

| | AWS (`us-east-1`) | GCP (`us-central1`) |
| --- | --- | --- |
| Layout | VPC across 3 AZs pinned by zone ID (`use1-az1`, `az2`, `az4`; EKS doesn't support `az3`). A private `/19` per AZ, sized for Cilium ENI-mode pod IPs, and a public `/24` per AZ | Custom-mode VPC with one node subnet, plus secondary ranges for pods and services |
| Egress | One NAT gateway (PoC; production would use one per AZ) | Cloud NAT on a reserved static IP, for the node subnet only |
| S3 traffic | Gateway endpoint on the private route tables, so WAL archiving skips the NAT | Through Cloud NAT over HTTPS |
| Logging | VPC flow logs to CloudWatch, encrypted with a customer-managed KMS key | Subnet flow logs, NAT error logs |
| Default access | Default security group stripped of all rules | Explicit, logged deny-all ingress firewall rule |

The backends are configured partly at init time, so no account-specific values
are committed:

```sh
tofu -chdir=infra/10-network/aws init \
  -backend-config="bucket=$(tofu -chdir=infra/00-bootstrap/aws output -raw state_bucket)" \
  -backend-config="region=us-east-1" \
  -backend-config="kms_key_id=$(tofu -chdir=infra/00-bootstrap/aws output -raw state_kms_key_arn)"
tofu -chdir=infra/10-network/aws plan

tofu -chdir=infra/10-network/gcp init \
  -backend-config="bucket=$(tofu -chdir=infra/00-bootstrap/gcp output -raw state_bucket)"
tofu -chdir=infra/10-network/gcp plan -var project_id=<project>
```

## Clusters (`infra/20-clusters`)

Both clusters run Kubernetes **1.36**, the newest minor version that is in EKS
standard support (1.34 to 1.37) and in Cilium 1.20's tested range (1.33 to 1.36).
The GKE stack checks at plan time that GKE offers it. The node OS on each cloud is
also a setting (`kubernetes.node_image` in `infra/modules/settings`). Nodes start
with the taint `node.cilium.io/agent-not-ready=true:NoExecute`, so they stay
`NotReady` and run nothing until Cilium is installed (`k8s/platform`).

| | EKS (`us-east-1`) | GKE (`us-central1-a`, zonal) |
| --- | --- | --- |
| Default CNI | None. The EKS module v21 never bootstraps self-managed add-ons, and no EKS add-ons are configured, so there is no VPC CNI, kube-proxy or CoreDNS | Legacy datapath (not Dataplane V2), GKE network policy add-on off |
| Nodes | 2 x `m6i.large` in the private subnets | 2 x `e2-standard-4`, private nodes. Created without a default node pool, so no node ever lacks the Cilium taint |
| Node OS | **Bottlerocket** (`BOTTLEROCKET_x86_64`): read-only root, no package manager. Admin (SSH) and control (SSM) host containers off, kernel lockdown `integrity`; debug with `kubectl debug node/...`. Encrypted OS and data volumes | **Container-Optimized OS** (`COS_CONTAINERD`): Google's equivalent, also read-only and minimal, with Shielded VM secure boot and integrity monitoring |
| API endpoint | Public and private; public limited to `api_allowed_cidrs` | Public; limited to `api_allowed_cidrs` |
| Secrets encryption | KMS key created by the EKS module | KMS key from `00-bootstrap/gcp` (Cloud KMS keys can never be deleted, so it outlives nightly teardowns) |
| Node credentials | IMDSv2 required, hop limit 1; the node role has no VPC CNI policy | Dedicated service account with `roles/container.defaultNodeServiceAccount`; GKE metadata server |
| Workload identity | IRSA, with roles for `cilium-operator` (only the ENI permissions in Cilium's docs) and `ebs-csi-controller-sa` | Workload Identity |

`api_allowed_cidrs` is required and rejects `/0`. Pass your own IP:

```sh
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"

tofu -chdir=infra/20-clusters/aws init \
  -backend-config="bucket=$(tofu -chdir=infra/00-bootstrap/aws output -raw state_bucket)" \
  -backend-config="region=us-east-1" \
  -backend-config="kms_key_id=$(tofu -chdir=infra/00-bootstrap/aws output -raw state_kms_key_arn)"
tofu -chdir=infra/20-clusters/aws plan -var "api_allowed_cidrs=[\"$MY_IP\"]"

# Re-apply 00-bootstrap/gcp first: it now also creates the GKE Secrets key.
tofu -chdir=infra/20-clusters/gcp init \
  -backend-config="bucket=$(tofu -chdir=infra/00-bootstrap/gcp output -raw state_bucket)"
tofu -chdir=infra/20-clusters/gcp plan -var project_id=<project> -var "api_allowed_cidrs=[\"$MY_IP\"]"

# Then add both clusters to your kubeconfig:
eval "$(tofu -chdir=infra/20-clusters/aws output -raw kubeconfig_command)"
eval "$(tofu -chdir=infra/20-clusters/gcp output -raw kubeconfig_command)"
```

EKS needs the **EBS CSI driver** for persistent volumes (CloudNativePG uses gp3).
It isn't an EKS add-on here, so `k8s/platform` installs it with Helm, using the
IRSA role from `tofu output ebs_csi_role_arn`.

## Platform (`k8s/`)

Flux reconciles each cluster from `main`: `k8s/clusters/<cloud>` is its entry
point, and it installs `k8s/platform/<cloud>` as Helm releases.

| Component | EKS | GKE | Notes |
| --- | --- | --- | --- |
| Cilium 1.20.5 + Hubble (Relay, UI) | ENI IPAM, kube-proxy replacement, operator on IRSA | GKE IPAM, native routing over the pods range | The only CNI on both |
| CoreDNS | Helm, as `kube-dns` on the cluster DNS IP | Built in | |
| cert-manager | yes | yes | TLS for the Barman Cloud plugin |
| CloudNativePG operator | yes | yes | `cnpg-system` |
| Barman Cloud plugin | yes | yes | WAL archive and base backups |
| EBS CSI driver | encrypted gp3 default StorageClass, IRSA | GKE's disk driver | |

Every chart is pinned to an exact version in its `HelmRelease`, and its values are
a plain `values.yaml` next to it (shared values in `base/`, cloud values in the
overlay). Account-specific values, such as the EKS API host and IAM role ARNs, are
not in git. `bootstrap.sh` writes them from `tofu output` into the
`flux-system/cluster-vars` ConfigMap, and Flux substitutes them into the manifests.
`cluster-vars.example.env` lists them for each cluster. Flux runs with strict
substitution: a manifest that uses a variable missing from its ConfigMap fails
to apply, instead of getting an empty string.

The Flux install manifests are committed (`make flux-manifests`), not created by
`flux bootstrap`, which would push to `main` directly. Controller images are pinned
by digest.

### Bootstrap order

Nothing can run before the CNI, and on EKS Flux can't resolve `github.com` before
CoreDNS. `make bootstrap` (which runs `k8s/bootstrap.sh`) therefore:

1. checks that the kube-context points at the cluster the stack built
2. creates the `cluster-vars` ConfigMap from `tofu output`
3. installs Cilium (and CoreDNS on EKS) with the Helm CLI, from the same values
   files and versions Flux uses, and waits for the nodes to become `Ready`
4. installs Flux with the deploy key and applies `k8s/clusters/<cloud>`

Flux then takes over the Cilium and CoreDNS releases and installs everything else
in dependency order (`dependsOn`).

Flux reads this private repo with a read-only deploy key. Create it once and keep
the private half under `secrets/`, which is gitignored:

```sh
ssh-keygen -t ed25519 -N '' -C flux -f secrets/flux-deploy-key
gh repo deploy-key add secrets/flux-deploy-key.pub --title flux   # read-only by default

make bootstrap CLOUD=aws CONTEXT=poc-mcpg
make bootstrap CLOUD=gcp CONTEXT="$(kubectl config get-contexts -o name | grep '^gke_')"

flux --context poc-mcpg get helmreleases -A
cilium --context poc-mcpg status --wait
```

## Primary database (EKS)

`pg-primary` in the `cnpg-db` namespace runs 2 PostgreSQL 18.7 instances, one per
node, on encrypted gp3 volumes. The Barman Cloud plugin archives WAL and base
backups to `s3://<wal bucket>/pg-primary/`:

- `archive_timeout = 60s`, so even a quiet database ships WAL every minute; that
  sets the replica's lag at about a minute
- a base backup is taken as soon as the cluster is ready (the GKE replica can't
  bootstrap without one), then nightly at 02:00 UTC; Barman keeps 7 days
- the image is pinned by digest, and Flux never prunes the `Cluster`

| Identity | Can | Limited to |
| --- | --- | --- |
| Writer: IRSA role for the `cnpg-db/pg-primary` service account | List, read, write and delete objects | `pg-primary/` in the WAL bucket, only through the VPC's S3 gateway endpoint; the KMS key only through S3 |
| Reader: IAM user for the GKE replica | List and read objects | `pg-primary/`, only from the GCP Cloud NAT IP; decrypt only through S3 |

The bucket is versioned, KMS-encrypted, private and TLS-only; superseded objects
expire after 7 days. No access key exists in OpenTofu: the replica's key is created
in the next phase and goes straight into a Kubernetes Secret. GKE can't use IRSA;
replacing the reader user with Workload Identity Federation is a follow-up.

The data layer is its own Flux Kustomization, which depends on the platform. Its
values (bucket and writer role) come from `infra/30-data/aws` through the
`flux-system/data-vars` ConfigMap. Until that ConfigMap exists, Flux applies
nothing, so the database can't start with empty values.

```sh
tofu -chdir=infra/30-data/aws init \
  -backend-config="bucket=$(tofu -chdir=infra/00-bootstrap/aws output -raw state_bucket)" \
  -backend-config="region=us-east-1" \
  -backend-config="kms_key_id=$(tofu -chdir=infra/00-bootstrap/aws output -raw state_kms_key_arn)"
tofu -chdir=infra/30-data/aws plan \
  -var "replica_egress_ips=$(tofu -chdir=infra/10-network/gcp output -json nat_egress_ips)"

make data-vars CLOUD=aws CONTEXT=poc-mcpg
kubectl --context poc-mcpg -n cnpg-db get cluster,backup -w
```

## Replica database (GKE)

`pg-replica` in `cnpg-db` on GKE is a CloudNativePG replica cluster with 1 instance
of the same PostgreSQL 18.7 image. It bootstraps from the primary's latest base
backup in S3, then keeps replaying WAL from the archive through the Barman Cloud
plugin. There is no network path between the clouds: the replica only makes
outbound HTTPS calls to S3 through Cloud NAT, so its lag is bounded by the
primary's `archive_timeout` (60s).

- **Read-only, from one IP.** The `aws-store-ro` ObjectStore uses the reader IAM user,
  which can only list and read `pg-primary/`, only from GCP's Cloud NAT IP. It
  sets no retention policy, and the replica has no WAL archiver, so it never
  writes to or deletes from the primary's archive.
- **Credentials never leave the cluster.** `make replica-credentials` creates the
  reader's access key and stores it, with the bucket region, in the
  `cnpg-db/aws-s3-reader` Secret. The key goes straight from the AWS API into the
  Kubernetes API, with no file and no OpenTofu state, and GKE encrypts Secrets
  with the KMS key from `00-bootstrap/gcp`. Running it again rotates the key: the
  new key is stored first, then the old one is deleted.
- **It won't start too early.** `make data-vars CLOUD=gcp` refuses to run until that
  Secret exists and the primary's first base backup is in S3; until it runs, Flux
  applies nothing in `k8s/data/gcp`.

```sh
GKE=$(kubectl config get-contexts -o name | grep '^gke_')
make replica-credentials CONTEXT="$GKE"
make data-vars CLOUD=gcp CONTEXT="$GKE"
kubectl --context "$GKE" -n cnpg-db get cluster pg-replica -w
```

**Promotion** is a manual step: set `spec.replica.enabled: false` on `pg-replica`
(in git, so Flux applies it). The promoted cluster then accepts writes. Before it
archives WAL anywhere, give it its own prefix or bucket and a writer identity; it
must never archive to `pg-primary/`.

## Network policies (`k8s/policies`)

Every pod in `cnpg-db` starts from **default deny** for ingress and egress (a plain
Kubernetes `NetworkPolicy`). `CiliumNetworkPolicy` rules then open exactly the
flows the databases need, using Cilium's entities and FQDN rules:

| # | Direction | From → to | Ports | Cluster | File |
| --- | --- | --- | --- | --- | --- |
| 0 | Both | Everything in `cnpg-db` | all | Both | `base/default-deny.yaml` |
| 1 | Egress | All pods → `kube-dns` in `kube-system`, through Cilium's DNS proxy | 53 UDP/TCP | Both | `base/allow-dns.yaml` |
| 2 | Egress | All pods → entity `kube-apiserver` | 443 | Both | `base/allow-kube-apiserver.yaml` |
| 3 | Ingress | CloudNativePG operator (`cnpg-system`) → instances; kubelet probes from the node | 8000, 5432; probes 8000 | Both | `base/allow-operator-and-probes.yaml` |
| 4 | Both | Instance ↔ instance of the same cluster (and its join job) | 5432, 8000 | Both | `<cloud>/allow-pg-*-instances.yaml` |
| 5 | Egress | Database pods → `s3.<region>.amazonaws.com`, `*.s3.<region>.amazonaws.com` | 443 | Both | `base/allow-s3.yaml` |
| 6 | Egress | Database pods → `sts.<region>.amazonaws.com`, `sts.amazonaws.com` (IRSA) | 443 | EKS | `aws/allow-sts.yaml` |
| 7 | Ingress | Namespace `app` → the current primary only (`cnpg.io/instanceRole: primary`) | 5432 | EKS | `aws/allow-app-to-primary.yaml` |

Prometheus scraping (port 9187) isn't opened, because nothing scrapes it yet.

The policies are their own Flux Kustomization, which depends on `data` and waits
for it to be healthy, so they're applied only once replication works. A policy
mistake then shows up as a new drop, not as a setup problem. The S3 and STS
hostnames use the bucket region from the `data-vars` ConfigMap.

Verify with Hubble on each cluster:

```sh
# Before the policies land: record the real flows (each should map to a rule above).
hubble observe -n cnpg-db --since 10m -o compact

# After: watch for drops while forcing a WAL switch and a backup.
hubble observe -n cnpg-db --verdict DROPPED -f

# Negative tests (EKS): no access from default, no internet egress; app can connect.
kubectl run probe --rm -it -n default --image=postgres:18 -- pg_isready -h pg-primary-rw.cnpg-db -t 5   # fails
kubectl exec -n cnpg-db pg-primary-1 -c postgres -- curl -m 5 https://example.com                         # fails
kubectl run probe --rm -it -n app --image=postgres:18 -- pg_isready -h pg-primary-rw.cnpg-db -t 5       # succeeds

kubectl cnpg status pg-primary -n cnpg-db   # EKS: continuous archiving still OK
kubectl cnpg status pg-replica -n cnpg-db   # GKE: still replaying WAL
```

## Local validation

Tool versions are pinned in `.tool-versions`. On macOS:

```sh
brew install opentofu trivy gitleaks pre-commit checkov helm kustomize kubeconform shellcheck
brew install terraform-linters/tap/tflint fluxcd/tap/flux
make hooks      # installs the pre-commit and commit-msg hooks
make validate   # every local check; no cloud credentials needed
```

`make validate` runs, without touching any cloud API or state backend:

1. `tofu fmt -check`, then `tofu init -backend=false` and `tofu validate` per stack
2. `tofu test` with mock providers
3. `pre-commit run --all-files`: gitleaks, checkov, trivy, tflint, shellcheck, file
   hygiene, and project guardrails (no `aws_iam_access_key`, no in-cluster providers in
   OpenTofu, per-cloud modules match their shared interface)
4. Kubernetes layer (`scripts/validate_k8s.py`, part of pre-commit), for every Flux
   layer of each cluster:
   - kustomize builds validated with kubeconform against Kubernetes 1.36 and strict
     schemas generated from the CRDs that Flux, the pinned charts and the pinned
     Cilium release install, so a misspelled field in a `Cluster`, `ObjectStore` or
     `CiliumNetworkPolicy` fails
   - `helm template` of every `HelmRelease` at its pinned version with its merged
     values, and every values key checked against the chart's schema
   - checkov's Kubernetes checks on the manifests exactly as Flux applies them
   - `${VARS}` checked against the `*.example.env` files, and the versions in
     `bootstrap.sh` and the Flux image digests against what Flux manages
5. `gitleaks git` over the full history

Commit messages are checked against Conventional Commits by a `commit-msg` hook.

CI (`.github/workflows/validate.yml`) runs `make validate` on every pull request
and on pushes to `main`, using the tool versions from `.tool-versions`. It has a
read-only token and no cloud credentials.
