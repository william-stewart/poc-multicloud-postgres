# Local validation only: nothing here talks to a cloud API or a cluster.
# Every stack is initialized with -backend=false, so no state is read or written.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# Every directory under infra/ that holds OpenTofu code is a stack.
STACKS := $(sort $(patsubst %/,%,$(dir $(shell find infra -name '*.tf' -not -path '*/.terraform/*' -not -path '*/.external_modules/*' 2>/dev/null))))

export TF_PLUGIN_CACHE_DIR ?= $(HOME)/.terraform.d/plugin-cache
export TF_IN_AUTOMATION := 1
$(shell mkdir -p "$(TF_PLUGIN_CACHE_DIR)")

.PHONY: help
help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

.PHONY: tools
tools: ## Check that every required tool is installed
	@for t in tofu tflint trivy checkov gitleaks pre-commit helm kustomize kubeconform flux shellcheck; do \
	  command -v $$t >/dev/null || { echo "missing: $$t"; exit 1; }; \
	done; echo "all tools present"

.PHONY: hooks
hooks: ## Install the pre-commit and commit-msg git hooks
	pre-commit install

.PHONY: fmt
fmt: ## Rewrite OpenTofu files in canonical format
	tofu fmt -recursive infra

.PHONY: tofu-fmt
tofu-fmt: ## Fail if any OpenTofu file is not formatted
	@if [ -d infra ]; then tofu fmt -check -diff -recursive infra; fi

.PHONY: tofu-validate
tofu-validate: ## tofu init -backend=false and tofu validate in every stack
	@for s in $(STACKS); do \
	  echo "==> validate $$s"; \
	  tofu -chdir=$$s init -backend=false -input=false >/dev/null; \
	  tofu -chdir=$$s validate -no-color; \
	done

.PHONY: tofu-test
tofu-test: tofu-validate ## tofu test (mock providers) in every stack that has tests
	@for s in $(STACKS); do \
	  if [ -d "$$s/tests" ]; then echo "==> test $$s"; tofu -chdir=$$s test -no-color; fi; \
	done

.PHONY: bootstrap
bootstrap: ## Install Cilium (+ CoreDNS on EKS) and Flux on a cluster: CLOUD=aws|gcp CONTEXT=<kube-context>
	@if [ -z "$(CLOUD)" ] || [ -z "$(CONTEXT)" ]; then \
	  echo "usage: make bootstrap CLOUD=<aws|gcp> CONTEXT=<kube-context> [DEPLOY_KEY=secrets/flux-deploy-key]" >&2; \
	  exit 2; \
	fi
	k8s/bootstrap.sh "$(CLOUD)" "$(CONTEXT)" $(if $(DEPLOY_KEY),"$(DEPLOY_KEY)")

.PHONY: flux-manifests
flux-manifests: ## Regenerate k8s/flux/gotk-components.yaml with the pinned flux CLI
	flux install --export > k8s/flux/gotk-components.yaml

.PHONY: secrets-history
secrets-history: ## Scan the full git history for secrets
	gitleaks git --redact --no-banner .

.PHONY: pre-commit
pre-commit: ## Run every pre-commit hook (gitleaks, checkov, trivy, tflint, ...) on all files
	pre-commit run --all-files

.PHONY: rulesets
rulesets: ## Create or update the GitHub rulesets in .github/rulesets (repo admin only)
	@repo=$$(gh repo view --json nameWithOwner -q .nameWithOwner); \
	for f in .github/rulesets/*.json; do \
	  name=$$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$$f"); \
	  id=$$(gh api "repos/$$repo/rulesets" --jq ".[] | select(.name == \"$$name\") | .id"); \
	  if [ -n "$$id" ]; then \
	    gh api -X PUT "repos/$$repo/rulesets/$$id" --input "$$f" >/dev/null && echo "updated: $$name"; \
	  else \
	    gh api -X POST "repos/$$repo/rulesets" --input "$$f" >/dev/null && echo "created: $$name"; \
	  fi; \
	done

.PHONY: validate
validate: tofu-fmt tofu-test pre-commit secrets-history ## Every local check; must pass before a PR
	@echo "make validate: OK"
