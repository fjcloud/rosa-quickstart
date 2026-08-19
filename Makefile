.PHONY: help deploy clean list output check-name _init _workspace _fmt _validate _tf-deploy _destroy _clean-workspace

# Cluster name (required for deploy, clean, output). Isolates Terraform state via workspaces.
NAME ?=
TF_VAR_ARGS := -var=cluster_name=$(NAME)
# Pin workspace per-command so parallel make deploy NAME=... from other shells do not race.
TF := TF_WORKSPACE=$(NAME) terraform

# Creds sourced in-process (never copied to another file).
AUTH_AWS ?= /usr/local/bin/auth-aws
DOTENV ?= .env

# Default target
help:
	@echo "Available targets:"
	@echo "  deploy NAME=<name>  - Source .env + auth-aws, then deploy a ROSA HCP cluster"
	@echo "  clean NAME=<name>   - Source .env + auth-aws, then destroy that cluster/workspace"
	@echo "  output NAME=<name>  - Print oc login command for that cluster"
	@echo "  list                - List cluster workspaces"
	@echo "  help                - Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make deploy NAME=fja-hcp1"
	@echo "  make deploy NAME=fja-hcp2    # parallel OK from another shell"
	@echo "  make output NAME=fja-hcp1"
	@echo "  make clean NAME=fja-hcp1"
	@echo "  make list"

check-name:
	@if [ -z "$(NAME)" ]; then \
		echo "Error: NAME is required (e.g. make deploy NAME=my-cluster)"; \
		exit 1; \
	fi
	@if ! echo "$(NAME)" | grep -Eq '^[a-z][a-z0-9-]{0,14}$$'; then \
		echo "Error: NAME must be a valid ROSA cluster name (lowercase, start with a letter, max 15 chars: [a-z0-9-])"; \
		exit 1; \
	fi

# Complete deployment workflow
deploy: check-name _init _fmt _validate _tf-deploy output

# Complete cleanup workflow (one cluster only; does not wipe shared .terraform/)
clean: check-name _init _destroy _clean-workspace

list:
	@if [ ! -d .terraform ]; then terraform init -input=false >/dev/null; fi
	@echo "Cluster workspaces:"
	@terraform workspace list | sed 's/^/  /'

output: check-name _workspace
	@$(TF) output -raw oc_login_command
	@echo

# Subtasks (internal use)
_init: check-name
	@echo "Initializing Terraform..."
	@terraform init -input=false
	@$(MAKE) --no-print-directory _workspace

_workspace: check-name
	@# Create workspace if missing; TF_WORKSPACE pins it for subsequent commands
	@if ! terraform workspace list 2>/dev/null | awk '{print $$NF}' | grep -qx '$(NAME)'; then \
		echo "Creating workspace $(NAME)..."; \
		TF_WORKSPACE= terraform workspace new $(NAME); \
	fi
	@echo "Using workspace $(NAME)"

_fmt:
	@echo "Formatting Terraform files..."
	@terraform fmt -recursive

_validate: check-name
	@echo "Validating Terraform configuration..."
	@$(TF) validate

# One shell: source .env + auth-aws then plan+apply (creds stay in memory only).
_tf-deploy: check-name
	@if [ ! -f "$(DOTENV)" ]; then echo "Error: $(DOTENV) not found (need RHCS_CLIENT_ID/SECRET)"; exit 1; fi
	@if [ ! -f "$(AUTH_AWS)" ]; then echo "Error: $(AUTH_AWS) not found"; exit 1; fi
	@bash -c 'set -euo pipefail; \
		echo "Loading RHCS credentials from $(DOTENV)..."; \
		source "$(DOTENV)"; \
		echo "Refreshing AWS credentials via $(AUTH_AWS)..."; \
		source "$(AUTH_AWS)"; \
		export TF_WORKSPACE="$(NAME)"; \
		echo "Generating Terraform execution plan for $(NAME)..."; \
		terraform plan $(TF_VAR_ARGS); \
		echo "Applying Terraform configuration for $(NAME)..."; \
		terraform apply -auto-approve $(TF_VAR_ARGS)'

# One shell: source .env + auth-aws then full destroy flow (creds stay in memory only).
_destroy: check-name _workspace
	@if [ ! -f "$(DOTENV)" ]; then echo "Error: $(DOTENV) not found (need RHCS_CLIENT_ID/SECRET)"; exit 1; fi
	@if [ ! -f "$(AUTH_AWS)" ]; then echo "Error: $(AUTH_AWS) not found"; exit 1; fi
	@bash -c 'set -euo pipefail; \
		echo "Loading RHCS credentials from $(DOTENV)..."; \
		source "$(DOTENV)"; \
		echo "Refreshing AWS credentials via $(AUTH_AWS)..."; \
		source "$(AUTH_AWS)"; \
		export TF_WORKSPACE="$(NAME)"; \
		_state="$$(terraform state list 2>/dev/null || true)"; \
		echo "Destroying ROSA cluster $(NAME) first..."; \
		if printf "%s\n" "$$_state" | grep -q "module.rosa_cluster_hcp"; then \
			terraform destroy -target=module.rosa_cluster_hcp -auto-approve $(TF_VAR_ARGS); \
		else \
			echo "  (cluster already gone from state)"; \
		fi; \
		echo "Cleaning leftover ROSA VPC dependencies (unmanaged SGs/ENIs)..."; \
		./cleanup_vpc_orphans.sh; \
		echo "Destroying remaining infrastructure for $(NAME)..."; \
		_state="$$(terraform state list 2>/dev/null || true)"; \
		if [ -n "$$_state" ]; then \
			if ! terraform destroy -auto-approve $(TF_VAR_ARGS); then \
				echo "Destroy failed; retrying orphan cleanup then destroy..."; \
				./cleanup_vpc_orphans.sh; \
				terraform destroy -auto-approve $(TF_VAR_ARGS); \
			fi; \
		else \
			echo "  (terraform state already empty)"; \
		fi'

_clean-workspace: check-name
	@echo "Removing Terraform workspace $(NAME)..."
	@# Unset TF_WORKSPACE so we can leave and delete it (env var pins the active workspace).
	@TF_WORKSPACE= terraform workspace select default >/dev/null
	@if TF_WORKSPACE= terraform workspace list | awk '{print $$NF}' | grep -qx '$(NAME)'; then \
		TF_WORKSPACE= terraform workspace delete $(NAME); \
	else \
		echo "  (workspace $(NAME) already removed)"; \
	fi
	@echo "Cleanup completed for $(NAME)."
