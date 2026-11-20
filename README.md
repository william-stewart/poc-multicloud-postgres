# poc-multicloud-postgres

A proof of concept for running CloudNativePG across clouds: a primary cluster on
EKS archives WAL to S3, and a replica cluster on GKE replays it. Both clusters
run Cilium as the only CNI, with default-deny network policies.

> Work in progress. The full write-up (architecture, trade-offs, evidence) is
> added once the stack runs end to end.

## Layout

| Path | Tool | Contents |
| --- | --- | --- |
| `infra/00-bootstrap/{aws,gcp}` | OpenTofu | Remote state buckets (S3 with native locking, GCS) |
| `infra/10-network/{aws,gcp}` | OpenTofu | VPCs, subnets, NAT, S3 gateway endpoint |
| `infra/20-clusters/{aws,gcp}` | OpenTofu | EKS and GKE without a default CNI |
| `infra/30-data/aws` | OpenTofu | WAL bucket and IAM |
| `k8s/` | Helm (helmfile) + kustomize | Everything that runs inside a cluster |

OpenTofu manages cloud primitives only. It has no Helm or Kubernetes providers,
and a pre-commit hook enforces that.

## Address plan

The ranges don't overlap, so a VPN and streaming replication can be added later.

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
   and project guardrails (no `aws_iam_access_key`, no in-cluster providers in OpenTofu)
4. `gitleaks git` over the full history

Commit messages are checked against Conventional Commits by a `commit-msg` hook.

CI (`.github/workflows/validate.yml`) runs `make validate` on every pull request
and on pushes to `main`, using the tool versions from `.tool-versions`. It has a
read-only token and no cloud credentials.

## Secrets

Nothing secret is ever committed: no cloud keys, kubeconfigs, state or plan
files, `.tfvars` with credentials, or `.env` files. Anything that has to be saved
locally goes under `secrets/`, which is gitignored.
