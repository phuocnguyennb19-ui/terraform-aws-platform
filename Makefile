# ===========================================================================
# terraform-aws-platform
#
# One root, one config file per environment. Every target that touches
# infrastructure REQUIRES CONFIG to be named on the command line. There is no
# default and there is no "current environment" — an ambient default is how a
# plan meant for dev gets applied to prod.
#
#   make plan  CONFIG=environments/dev/config.yaml
#   make apply CONFIG=environments/dev/config.yaml
#
# The environment is not a flag: it is `global.environment` inside the config,
# and every target prints it before doing anything.
#
# Run `make help` for the full list.
# ===========================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# CONFIG is a path relative to the repository root, because that is the
# directory Terraform must run from: the root resolves it as
# file("$${path.cwd}/$${var.config_file}").
CONFIG    ?= config.yaml
PLAN_FILE := tfplan

CONFIG_ENV = $(shell sed -n 's/^[[:space:]]*environment:[[:space:]]*\([a-z][a-z0-9-]*\).*/\1/p' $(CONFIG) 2>/dev/null | head -1)

# Backend settings live beside the config they belong to, so a config and the
# state it writes cannot be mismatched from the command line.
BACKEND = $(dir $(CONFIG))backend.hcl

# Guard: a target needs a config, and that config must name its environment. An
# unnamed environment is the one case CLAUDE.md treats as production, so
# refusing here is cheaper than finding out during apply.
define require_config
	@if [ ! -f "$(CONFIG)" ]; then \
		echo "ERROR: no config at '$(CONFIG)'."; \
		echo "       Per-environment configs live in environments/<env>/config.yaml."; \
		echo "       To try an example:  cp examples/config/base.yaml config.yaml"; exit 1; \
	fi
	@if ! grep -qE '^[[:space:]]+environment:[[:space:]]*[a-z]' "$(CONFIG)"; then \
		echo "ERROR: $(CONFIG) does not set global.environment."; \
		echo "       Refusing to run a stack whose environment is unknown."; exit 1; \
	fi
	@echo "  config      : $(CONFIG)"
	@echo "  environment : $(CONFIG_ENV)"
	@echo ""
endef

# Guard: refuse a destructive operation on a prod config without an explicit
# acknowledgement naming the environment.
define require_prod_ack
	@if [ "$(CONFIG_ENV)" = "prod" ] && [ "$(CONFIRM)" != "yes-destroy-prod" ]; then \
		echo ""; \
		echo "REFUSED: '$@' targets PRODUCTION (global.environment: prod in $(CONFIG))."; \
		echo ""; \
		echo "  This destroys live infrastructure. RDS and the ALB carry deletion"; \
		echo "  protection and will block, leaving a half-destroyed environment."; \
		echo ""; \
		echo "  If that is genuinely what you want:"; \
		echo "      make $@ CONFIG=$(CONFIG) CONFIRM=yes-destroy-prod"; \
		echo ""; \
		exit 1; \
	fi
endef

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "terraform-aws-platform"
	@echo ""
	@echo "  Every infrastructure target needs CONFIG=environments/<env>/config.yaml."
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ---------------------------------------------------------------------------
# Core loop
# ---------------------------------------------------------------------------

.PHONY: init
init: ## Initialise against the config's remote state — make init CONFIG=environments/dev/config.yaml
	$(require_config)
	@if [ ! -f "$(BACKEND)" ]; then \
		echo "ERROR: no $(BACKEND). It names the state bucket and key for this config."; exit 1; \
	fi
	terraform init -reconfigure -input=false -backend-config=$(BACKEND)

.PHONY: init-local
init-local: ## Initialise WITHOUT a backend, for fmt/validate only
	terraform init -backend=false -input=false

.PHONY: fmt
fmt: ## Rewrite every .tf file into canonical format
	terraform fmt -recursive

.PHONY: fmt-check
fmt-check: ## Fail if any file is not canonically formatted (CI gate)
	terraform fmt -check -recursive

.PHONY: validate
validate: ## Validate the configuration
	terraform validate

.PHONY: config-check
config-check: ## Parse every environment config and print what it would build
	@for c in environments/*/config.yaml; do \
		echo "══ $$c ══"; \
		env=$$(sed -n 's/^[[:space:]]*environment:[[:space:]]*\([a-z][a-z0-9-]*\).*/\1/p' $$c | head -1); \
		if [ -z "$$env" ]; then echo "  ERROR: no global.environment"; exit 1; fi; \
		echo "  environment : $$env"; \
		echo -n "  modules     :"; \
		grep -B1 '^  enabled: true' $$c | grep -E '^[a-z0-9_]+:' | tr -d ':' | tr '\n' ' '; \
		echo ""; \
	done

.PHONY: plan
plan: ## Plan and save the plan to a file — make plan CONFIG=environments/dev/config.yaml
	$(require_config)
	terraform plan -input=false -var config_file=$(CONFIG) -out=$(PLAN_FILE)
	@echo ""
	@echo "Plan saved to ./$(PLAN_FILE) for environment '$(CONFIG_ENV)'."
	@echo "Review it, then: make apply CONFIG=$(CONFIG)"

.PHONY: apply
apply: ## Apply the SAVED plan file — make apply CONFIG=environments/dev/config.yaml
	$(require_config)
	@if [ ! -f "$(PLAN_FILE)" ]; then \
		echo "ERROR: no saved plan at ./$(PLAN_FILE). Run: make plan CONFIG=$(CONFIG)"; exit 1; \
	fi
	terraform apply -input=false $(PLAN_FILE)
	@rm -f $(PLAN_FILE)

.PHONY: show
show: ## Render the saved plan as text
	terraform show $(PLAN_FILE)

.PHONY: show-json
show-json: ## Render the saved plan as JSON, for policy tooling
	terraform show -json $(PLAN_FILE)

.PHONY: output
output: ## Show stack outputs — what an application config puts under existing:
	terraform output

.PHONY: plan-target
plan-target: ## Plan one module — make plan-target CONFIG=… TARGET=module.vpc
	$(require_config)
	@if [ -z "$(TARGET)" ]; then echo "ERROR: TARGET is required, e.g. TARGET=module.vpc"; exit 1; fi
	terraform plan -input=false -var config_file=$(CONFIG) -target=$(TARGET)

.PHONY: refresh
refresh: ## Reconcile state with reality without changing anything
	$(require_config)
	terraform apply -refresh-only -input=false -var config_file=$(CONFIG)

.PHONY: unlock
unlock: ## Force-release a stuck state lock — make unlock CONFIG=… LOCK_ID=<id>
	$(require_config)
	@if [ -z "$(LOCK_ID)" ]; then echo "ERROR: LOCK_ID is required."; exit 1; fi
	terraform force-unlock $(LOCK_ID)

.PHONY: destroy
destroy: ## Destroy a stack. A prod config requires CONFIRM=yes-destroy-prod
	$(require_config)
	$(require_prod_ack)
	terraform destroy -input=false -var config_file=$(CONFIG)

# ---------------------------------------------------------------------------
# Quality gates
# ---------------------------------------------------------------------------

.PHONY: lint
lint: ## Run tflint across the root
	@command -v tflint >/dev/null || { echo "tflint not installed: brew install tflint"; exit 1; }
	tflint --init
	tflint --config=$(CURDIR)/.tflint.hcl

.PHONY: sec
sec: ## Run trivy config (the maintained successor to tfsec)
	@command -v trivy >/dev/null || { echo "trivy not installed: brew install trivy"; exit 1; }
	trivy config --config trivy.yaml .

.PHONY: checkov
checkov: ## Run checkov
	@command -v checkov >/dev/null || { echo "checkov not installed: pip install checkov"; exit 1; }
	checkov --config-file .checkov.yaml

.PHONY: scan
scan: sec checkov ## Run every security scanner

.PHONY: ci
ci: fmt-check init-local validate config-check ## Everything CI runs that needs no credentials
	@echo ""
	@echo "CI checks passed."

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

.PHONY: bootstrap-state
bootstrap-state: ## Print the commands that create the state bucket and lock table
	$(require_config)
	@echo "  The state bucket and lock table have to exist before the first apply."
	@echo "  Create them once, out of band. Substitute your own bucket name and"
	@echo "  then put it in $(BACKEND)."
	@echo ""
	@echo "  BUCKET=my-terraform-state-$(CONFIG_ENV)"
	@echo "  REGION=ap-southeast-1"
	@echo ""
	@echo "  aws s3api create-bucket --bucket \$$BUCKET --region \$$REGION \\"
	@echo "      --create-bucket-configuration LocationConstraint=\$$REGION"
	@echo ""
	@echo "  # Versioning: the only way back from a corrupted or truncated state."
	@echo "  aws s3api put-bucket-versioning --bucket \$$BUCKET \\"
	@echo "      --versioning-configuration Status=Enabled"
	@echo ""
	@echo "  # Encryption: state holds every resolved value in plaintext."
	@echo "  aws s3api put-bucket-encryption --bucket \$$BUCKET \\"
	@echo "      --server-side-encryption-configuration \\"
	@echo "      '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\"},\"BucketKeyEnabled\":true}]}'"
	@echo ""
	@echo "  aws s3api put-public-access-block --bucket \$$BUCKET \\"
	@echo "      --public-access-block-configuration \\"
	@echo "      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
	@echo ""
	@echo "  # Lock table (Terraform 1.5.7). On >= 1.10 use use_lockfile instead."
	@echo "  aws dynamodb create-table --table-name terraform-locks \\"
	@echo "      --attribute-definitions AttributeName=LockID,AttributeType=S \\"
	@echo "      --key-schema AttributeName=LockID,KeyType=HASH \\"
	@echo "      --billing-mode PAY_PER_REQUEST --region \$$REGION"
	@echo ""

.PHONY: clean
clean: ## Remove local plan files and provider caches (never touches state)
	@find . -name 'tfplan*' -delete
	@find . -type d -name '.terraform' -prune -exec rm -rf {} + 2>/dev/null || true
	@echo "  Cleaned. .terraform.lock.hcl files are kept on purpose."
