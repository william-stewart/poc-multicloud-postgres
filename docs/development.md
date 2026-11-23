# Development

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
| `k8s/*.sh` | `bootstrap.sh`, `data-vars.sh`, `app-credentials.sh` (run through `make`) and their shared `lib.sh` |
| `test/e2e` | The local end-to-end test (`make e2e`) and its overlays of `k8s/data` |
| `test/live` | The drill on the live clusters (`make live-drill`) |
| `scripts` | The module contract check, the Kubernetes validator and `cilium-enis.sh` |
| `.github` | The CI workflow, branch rulesets and Renovate configuration |
| `docs` | Deploy and operate runbook, end-to-end test guide, design notes, this guide and the README diagram's source |
| `evidence/e2e` | Results of end-to-end runs |
| `evidence/live` | Results and screenshots from the live clusters |
