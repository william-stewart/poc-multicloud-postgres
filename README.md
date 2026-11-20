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
regions, zones, address plan and base labels. Every stack calls it, so each value
is defined once. Validation rejects address ranges that overlap, fall outside
`10.0.0.0/8`, or have host bits set.

**Matching interfaces, separate implementations.** Each cloud has its own module
(`infra/modules/network/aws`, `.../gcp`), and each stack picks the one for its
cloud. There is no `cloud = "aws"` switch inside a module. Both modules declare the
inputs and outputs listed in `infra/modules/network/contract.json`:

| Inputs | Outputs |
| --- | --- |
| `name`, `region`, `cidr`, `labels` | `network_id`, `network_name`, `private_subnet_ids`, `nat_egress_ips` |

Features that exist on only one cloud stay as extra inputs and outputs on that
module: AWS zone IDs and the S3 gateway endpoint, GCP secondary ranges. A
pre-commit hook (`scripts/check_module_contracts.py`) fails if an implementation
is missing a contract input or output, or declares an input with a different type.

This keeps each stack to one provider and one set of credentials, and keeps the
differences between clouds visible in review. The portability layer is
Kubernetes, not OpenTofu.

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
