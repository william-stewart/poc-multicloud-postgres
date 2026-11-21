# poc-multicloud-postgres

A proof of concept for running CloudNativePG across clouds: a primary cluster on
EKS archives WAL to S3, and a replica cluster on GKE replays it. Both clusters
run Cilium as the only CNI, with default-deny network policies.

> Work in progress. The full write-up (architecture, trade-offs, evidence) is
> added once the stack runs end to end.

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
| `infra/30-data/aws` | OpenTofu | WAL bucket and IAM |
| `k8s/` | Helm (helmfile) + kustomize | Everything that runs inside a cluster |

OpenTofu manages cloud primitives only. It has no Helm or Kubernetes providers,
and a pre-commit hook enforces that.

## Shared settings and module interfaces

Two patterns keep the clouds consistent without hiding their differences.

**One settings module.** `infra/modules/settings` has no providers and no
resources. It returns the values both clouds must agree on: the name prefix,
regions, zones, address plan, Kubernetes version and node count, and base labels.
Every stack calls it, so each value
is defined once. Validation rejects address ranges that overlap, fall outside
`10.0.0.0/8`, or have host bits set.

**Matching interfaces, separate implementations.** Each cloud has its own module
(`infra/modules/network/aws`, `.../gcp`), and each stack picks the one for its
cloud. There is no `cloud = "aws"` switch inside a module. Each pair declares the
inputs and outputs listed in its `contract.json`:

| Contract | Inputs | Outputs |
| --- | --- | --- |
| `modules/network` | `name`, `region`, `cidr`, `labels` | `network_id`, `network_name`, `private_subnet_ids`, `nat_egress_ips` |
| `modules/network-lookup` | `name`, `region` | the same four as `network` |
| `modules/cluster` | `name`, `kubernetes_version`, `node_count`, `machine_type`, `api_allowed_cidrs`, `labels` | `cluster_name`, `cluster_endpoint`, `cluster_ca_certificate`, `oidc_issuer_url`, `kubeconfig_command` |

Features that exist on only one cloud stay as extra inputs and outputs on that
module: for example AWS zone IDs, the S3 gateway endpoint and IRSA roles, or GCP
secondary ranges and the Secrets encryption key.

Two checks enforce the interface, and each catches what the other can't:

| Check | What it verifies | How |
| --- | --- | --- |
| `scripts/check_module_contracts.py` (pre-commit hook) | Every contract input and output is **declared**, and input types match | Reads the `.tf` files; no providers needed |
| `infra/tests/contracts` (`tofu test`) | The outputs' **values** have the contracted shape, for example `private_subnet_ids` a list (not a tuple) of strings, `nat_egress_ips` a list of IPv4 addresses, `cluster_endpoint` an `https://` URL | Runs each implementation against mock providers |

This contract format and checker are specific to this repo, not an industry
standard. OpenTofu has no built-in notion of a module interface.

This keeps each stack to one provider and one set of credentials, and keeps the
differences between clouds visible in review. The portability layer is
Kubernetes, not OpenTofu.

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
with the taint
`node.cilium.io/agent-not-ready=true:NoExecute`, so they stay `NotReady` and run
nothing until Cilium is installed (`k8s/platform`).

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

## Local validation

Tool versions are pinned in `.tool-versions`. On macOS:

```sh
brew install opentofu trivy gitleaks pre-commit checkov
brew tap terraform-linters/tap && brew install terraform-linters/tap/tflint
make hooks      # installs the pre-commit and commit-msg hooks
make validate   # every local check; no cloud credentials needed
```

`make validate` runs, without touching any cloud API or state backend:

1. `tofu fmt -check`, then `tofu init -backend=false` and `tofu validate` per stack
2. `tofu test` with mock providers
3. `pre-commit run --all-files`: gitleaks, checkov, trivy, tflint, file hygiene,
   and project guardrails (no `aws_iam_access_key`, no in-cluster providers in OpenTofu,
   per-cloud modules match their shared interface)
4. `gitleaks git` over the full history

Commit messages are checked against Conventional Commits by a `commit-msg` hook.

CI (`.github/workflows/validate.yml`) runs `make validate` on every pull request
and on pushes to `main`, using the tool versions from `.tool-versions`. It has a
read-only token and no cloud credentials.

## Branch protection

`main` is protected by two GitHub rulesets, kept as code in `.github/rulesets/`
and applied with `make rulesets`. That target creates each ruleset, or updates it
if one with the same name already exists.

- **main: require pull request.** Every change to `main`, including the owner's,
  goes through a pull request. Force pushes and branch deletion are blocked, and
  review threads must be resolved. PRs merge with a merge commit or a rebase, never
  a squash, so the commit history is kept. No reviews are required because a solo
  owner can't approve their own PR. Nobody can bypass this ruleset.
- **main: only admins can merge.** Only the repository admin role may update
  `main`, and only through a pull request. Anyone given write access later can
  open PRs but can't merge them.

## Secrets

Nothing secret is ever committed: no cloud keys, kubeconfigs, state or plan
files, `.tfvars` with credentials, or `.env` files. Anything that has to be saved
locally goes under `secrets/`, which is gitignored.
