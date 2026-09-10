# ===========================================================================
# terraform-aws-platform
#
# Every target that touches an environment REQUIRES ENV to be named on the
# command line. There is no default and there is no "current environment" —
# an ambient default is how a plan meant for dev gets applied to prod.
#
#   make plan ENV=dev
#   make apply ENV=prod
#
# Run `make help` for the full list.
# ===========================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENVS      := dev staging prod
ENV_DIR   := environments/$(ENV)
PLAN_FILE := tfplan-$(ENV)

# The config-driven entry point. CONFIG is a path relative to the repository
# root, because that is the directory Terraform must run from: the root and
# every module resolve it as file("$${path.cwd}/$${var.config_file}").
CONFIG     ?= config.yaml
STACK_PLAN := tfplan-stack
CONFIG_ENV  = $(shell sed -n 's/^[[:space:]]*environment:[[:space:]]*\([a-z][a-z0-9-]*\).*/\1/p' $(CONFIG) 2>/dev/null | head -1)

# Guard: every environment-scoped target depends on this.
define require_env
	@if [ -z "$(ENV)" ]; then \
		echo "ERROR: ENV is required. Usage: make $@ ENV=<$(shell echo $(ENVS) | tr ' ' '|')>"; exit 1; \
	fi
	@if [ ! -d "$(ENV_DIR)" ]; then \
		echo "ERROR: unknown environment '$(ENV)'. Known: $(ENVS)"; exit 1; \
	fi
endef

# Guard: refuse a destructive prod operation without an explicit acknowledgement.
define require_prod_ack
	@if [ "$(ENV)" = "prod" ] && [ "$(CONFIRM)" != "yes-destroy-prod" ]; then \
		echo ""; \
		echo "REFUSED: '$@' targets PRODUCTION."; \
		echo ""; \
		echo "  This destroys live infrastructure. RDS and the ALB carry deletion"; \
		echo "  protection and will block, leaving a half-destroyed environment."; \
		echo ""; \
		echo "  If that is genuinely what you want:"; \
		echo "      make $@ ENV=prod CONFIRM=yes-destroy-prod"; \
		echo ""; \
		exit 1; \
	fi
endef

# Guard: a config-driven stack target needs a config, and that config must name
# its environment. An unnamed environment is the one case CLAUDE.md treats as
# production, so refusing here is cheaper than finding out during apply.
define require_config
	@if [ ! -f "$(CONFIG)" ]; then \
		echo "ERROR: no config at '$(CONFIG)'."; \
		echo "       CI copies the application repo's config in. To try an example:"; \
		echo "           cp examples/config/base.yaml config.yaml"; exit 1; \
	fi
	@if ! grep -qE '^[[:space:]]+environment:[[:space:]]*[a-z]' "$(CONFIG)"; then \
		echo "ERROR: $(CONFIG) does not set global.environment."; \
		echo "       Refusing to run a stack whose environment is unknown."; exit 1; \
	fi
	@echo "  config      : $(CONFIG)"
	@echo "  environment : $(CONFIG_ENV)"
	@echo ""
endef

# Guard: refuse a destructive operation on a prod CONFIG without an acknowledgement.
define require_config_prod_ack
	@if [ "$(CONFIG_ENV)" = "prod" ] && [ "$(CONFIRM)" != "yes-destroy-prod" ]; then \
		echo ""; \
		echo "REFUSED: '$@' targets PRODUCTION (global.environment: prod in $(CONFIG))."; \
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
	@echo "  Every environment target needs ENV=<dev|staging|prod>."
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ---------------------------------------------------------------------------
# Core loop
# ---------------------------------------------------------------------------

.PHONY: init
init: ## Initialise an environment against its remote state — make init ENV=dev
	$(require_env)
	cd $(ENV_DIR) && terraform init -reconfigure -input=false -backend-config=backend.hcl

.PHONY: init-local
init-local: ## Initialise WITHOUT a backend, for fmt/validate only
	$(require_env)
	cd $(ENV_DIR) && terraform init -backend=false -input=false

.PHONY: fmt
fmt: ## Rewrite every .tf file into canonical format
	terraform fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Fail if any file is not canonically formatted (CI gate)
	terraform fmt -recursive -check -diff .

.PHONY: validate
validate: ## Validate one environment — make validate ENV=dev
	$(require_env)
	cd $(ENV_DIR) && terraform validate

.PHONY: validate-all
validate-all: ## Validate every environment
	@for e in $(ENVS); do \
		echo "══ $$e ══"; \
		( cd environments/$$e && terraform init -backend=false -input=false >/dev/null && terraform validate ) || exit 1; \
	done

.PHONY: plan
plan: ## Plan and save the plan to a file — make plan ENV=dev
	$(require_env)
	cd $(ENV_DIR) && terraform plan -input=false -out=$(PLAN_FILE)
	@echo ""
	@echo "Plan saved to $(ENV_DIR)/$(PLAN_FILE). Review it, then: make apply ENV=$(ENV)"

.PHONY: apply
apply: ## Apply the SAVED plan file — make apply ENV=dev
	$(require_env)
	@if [ ! -f "$(ENV_DIR)/$(PLAN_FILE)" ]; then \
		echo "ERROR: no saved plan at $(ENV_DIR)/$(PLAN_FILE). Run: make plan ENV=$(ENV)"; exit 1; \
	fi
	cd $(ENV_DIR) && terraform apply -input=false $(PLAN_FILE)
	@rm -f $(ENV_DIR)/$(PLAN_FILE)

.PHONY: show
show: ## Render the saved plan as text
	$(require_env)
	cd $(ENV_DIR) && terraform show $(PLAN_FILE)

.PHONY: show-json
show-json: ## Render the saved plan as JSON, for policy tooling
	$(require_env)
	cd $(ENV_DIR) && terraform show -json $(PLAN_FILE)

.PHONY: output
output: ## Show environment outputs
	$(require_env)
	cd $(ENV_DIR) && terraform output

.PHONY: destroy
destroy: ## Destroy an environment. Prod requires CONFIRM=yes-destroy-prod
	$(require_env)
	$(require_prod_ack)
	cd $(ENV_DIR) && terraform destroy -input=false

# ---------------------------------------------------------------------------
# Targeted operations
# ---------------------------------------------------------------------------

.PHONY: plan-target
plan-target: ## Plan one module — make plan-target ENV=dev TARGET=module.vpc
	$(require_env)
	@if [ -z "$(TARGET)" ]; then echo "ERROR: TARGET is required, e.g. TARGET=module.vpc"; exit 1; fi
	cd $(ENV_DIR) && terraform plan -input=false -target=$(TARGET)

.PHONY: refresh
refresh: ## Reconcile state with reality without changing anything
	$(require_env)
	cd $(ENV_DIR) && terraform plan -input=false -refresh-only

.PHONY: unlock
unlock: ## Force-release a stuck state lock — make unlock ENV=dev LOCK_ID=<id>
	$(require_env)
	@if [ -z "$(LOCK_ID)" ]; then echo "ERROR: LOCK_ID is required (printed in the lock error)"; exit 1; fi
	@echo "Only do this when you are certain no other apply is running."
	cd $(ENV_DIR) && terraform force-unlock $(LOCK_ID)

# ---------------------------------------------------------------------------
# Config-driven stacks — the entry point CI uses
#
# One config file is one Terraform state. The config and its backend.hcl belong
# to the APPLICATION repository and are copied into a clone of this one; see
# examples/config/README.md for the pipeline.
#
#   make stack-plan CONFIG=config.yaml
#   make stack-apply CONFIG=config.yaml
# ---------------------------------------------------------------------------

.PHONY: stack-init
stack-init: ## Initialise the root stack against its remote state — make stack-init CONFIG=config.yaml
	$(require_config)
	@if [ ! -f backend.hcl ]; then \
		echo "ERROR: no ./backend.hcl. CI copies it in beside the config; it names the state bucket and key."; exit 1; \
	fi
	terraform init -reconfigure -input=false -backend-config=backend.hcl

.PHONY: stack-init-local
stack-init-local: ## Initialise WITHOUT a backend, for fmt/validate only
	terraform init -backend=false -input=false

.PHONY: stack-validate
stack-validate: ## Validate the root stack against a config
	$(require_config)
	terraform validate

.PHONY: stack-plan
stack-plan: ## Plan the root stack and save the plan — make stack-plan CONFIG=config.yaml
	$(require_config)
	terraform plan -input=false -var config_file=$(CONFIG) -out=$(STACK_PLAN)
	@echo ""
	@echo "Plan saved to ./$(STACK_PLAN) for environment '$(CONFIG_ENV)'."
	@echo "Review it, then: make stack-apply CONFIG=$(CONFIG)"

.PHONY: stack-apply
stack-apply: ## Apply the SAVED root stack plan
	$(require_config)
	@if [ ! -f "$(STACK_PLAN)" ]; then \
		echo "ERROR: no saved plan at ./$(STACK_PLAN). Run: make stack-plan CONFIG=$(CONFIG)"; exit 1; \
	fi
	terraform apply -input=false $(STACK_PLAN)
	@rm -f $(STACK_PLAN)

.PHONY: stack-show
stack-show: ## Render the saved root stack plan as text
	terraform show $(STACK_PLAN)

.PHONY: stack-output
stack-output: ## Show the root stack outputs — what an application config puts under existing:
	terraform output

.PHONY: stack-destroy
stack-destroy: ## Destroy the root stack. A prod config requires CONFIRM=yes-destroy-prod
	$(require_config)
	$(require_config_prod_ack)
	terraform destroy -input=false -var config_file=$(CONFIG)

# ---------------------------------------------------------------------------
# Quality gates
# ---------------------------------------------------------------------------

.PHONY: lint
lint: ## Run tflint across modules and environments
	@command -v tflint >/dev/null || { echo "tflint not installed: brew install tflint"; exit 1; }
	tflint --init
	@for d in modules/*/ environments/*/; do \
		echo "══ $$d ══"; \
		tflint --chdir=$$d --config=$(CURDIR)/.tflint.hcl || exit 1; \
	done

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

.PHONY: env-drift
env-drift: ## Fail if the three environment roots have structurally diverged
	@echo "Environments must differ only in terraform.tfvars and backend.hcl."
	@fail=0; \
	for f in main.tf variables.tf outputs.tf providers.tf backend.tf versions.tf; do \
		for e in staging prod; do \
			if ! diff -q environments/dev/$$f environments/$$e/$$f >/dev/null 2>&1; then \
				echo "  DRIFT: environments/$$e/$$f differs from environments/dev/$$f"; \
				diff -u environments/dev/$$f environments/$$e/$$f | head -20; \
				fail=1; \
			fi; \
		done; \
	done; \
	if [ $$fail -eq 0 ]; then echo "  OK — all three roots are identical."; else exit 1; fi

.PHONY: versions-check
versions-check: ## Fail if an environment's versions.tf has drifted from the canonical one
	@fail=0; \
	for e in $(ENVS); do \
		if ! diff -q versions.tf environments/$$e/versions.tf >/dev/null 2>&1; then \
			echo "  DRIFT: environments/$$e/versions.tf differs from ./versions.tf"; fail=1; \
		fi; \
	done; \
	if [ $$fail -eq 0 ]; then echo "  OK — version constraints are consistent."; else \
		echo "  Fix with: make versions-sync"; exit 1; fi

.PHONY: versions-sync
versions-sync: ## Copy the canonical versions.tf into every environment
	@for e in $(ENVS); do cp versions.tf environments/$$e/versions.tf; echo "  synced environments/$$e/versions.tf"; done

.PHONY: ci
ci: fmt-check versions-check env-drift validate-all ## Everything CI runs that needs no credentials
	@echo ""
	@echo "CI checks passed."

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

.PHONY: bootstrap-state
bootstrap-state: ## Print the commands that create the state bucket and lock table
	$(require_env)
	@echo ""
	@echo "  The state bucket and lock table have to exist before the first apply."
	@echo "  Create them once, out of band. Substitute your own bucket name and"
	@echo "  then put it in $(ENV_DIR)/backend.hcl."
	@echo ""
	@echo "  BUCKET=my-terraform-state-$(ENV)"
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
	@find . -name 'tfplan-*' -delete
	@find . -type d -name '.terraform' -prune -exec rm -rf {} + 2>/dev/null || true
	@echo "  Cleaned. .terraform.lock.hcl files are kept on purpose."
