# Agent instructions: poc-multicloud-postgres

Instructions for AI coding agents working in this repository. The admin reviews every
change and is the only one who runs anything against the real clouds.

## What you may and may not run
- You write code and validate it locally. The human runs everything against real clouds.
- NEVER run: `tofu plan`, `tofu apply`, `tofu destroy`, `tofu import`, `tofu state ...`,
  `flux` commands that change a cluster, or any `kubectl`/`helm` command against a real
  cluster.
- Always `tofu init -backend=false`. You have no cloud credentials and must not ask for them.
- A change is ready for review only when `make validate` passes.
- End-to-end and cluster tests run locally (`make e2e`, on Rancher Desktop); don't add
  CI jobs for them.

## Architecture boundary
- OpenTofu (`infra/`) contains cloud primitives only: networks, NAT, managed control planes,
  node groups, buckets, IAM. No `helm`, `kubernetes` or `kubectl` providers, no EKS add-ons.
- Everything in-cluster lives in `k8s/` as Helm charts or kustomize manifests that Flux
  applies.

## Commits
- Conventional Commits: `type(scope): summary`, imperative, 72 characters or fewer, with a body
  explaining why when it isn't obvious.
- One logical unit per commit; the repo must pass `make validate` after each one.
- One short-lived branch per change; open a PR with `gh pr create` and stop for human review.
- No AI attribution of any kind: no `Co-Authored-By` trailers, no "Generated with" lines,
  in commits or PR descriptions.

## Writing
- American English (initialize, honor).
- No "we", "our" or "ours" in docs: say what the admin is responsible for.

## Secrets
- Never commit secrets: cloud keys, kubeconfigs, tfstate or tfplan files, tfvars with
  credentials, Kubernetes Secret manifests with data, `.env` files, private keys.
- Never create `aws_iam_access_key` in OpenTofu.
- Any secret saved locally goes under `secrets/`, which must be in `.gitignore` before the
  file is created. Run `pre-commit run --all-files` (includes gitleaks) before every commit.
- Never commit cloud account IDs, project IDs or personal details, including in
  screenshots under `evidence/`.
