.PHONY: help prereq deploy clean list output check-name _init _workspace _fmt _validate _tf-deploy _destroy _clean-workspace

# Cluster name (required for deploy, clean, output). Isolates Terraform state via workspaces.
NAME ?=
# NO_CNI=true opts out of OVN-Kubernetes (rosa --no-cni). Default keeps the CNI.
NO_CNI ?= false
TF_VAR_ARGS := -var=cluster_name=$(NAME) -var=no_cni=$(NO_CNI)
# Pin workspace per-command so parallel make deploy NAME=... from other shells do not race.
TF := TF_WORKSPACE=$(NAME) terraform

# Creds sourced in-process (never copied to another file).
# Existing AWS credentials win. auth-aws is only the fallback when this shell has none.
export AUTH_AWS ?= /usr/local/bin/auth-aws
export DOTENV ?= .env
export PATH := $(HOME)/.local/bin:$(PATH)

# Default target
help:
	@echo "Available targets:"
	@echo "  prereq              - Install tools, link the AWS account, check quota"
	@echo "  deploy NAME=<name>  - Run prereq, then deploy a ROSA HCP cluster"
	@echo "  clean NAME=<name>   - Destroy that cluster/workspace"
	@echo "  output NAME=<name>  - Print oc login command for that cluster"
	@echo "  list                - List cluster workspaces"
	@echo "  help                - Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make deploy NAME=fja-hcp1"
	@echo "  make deploy NAME=fja-nocni NO_CNI=true"
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

prereq:
	@bash scripts/prereq.sh

# Complete deployment workflow
deploy: check-name prereq _init _fmt _validate _tf-deploy output

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

# One shell: load RHCS + AWS credentials, then plan+apply (creds stay in memory only).
_tf-deploy: check-name
	@bash -c 'set -euo pipefail; \
		source "$(CURDIR)/scripts/load-creds.sh"; \
		export TF_WORKSPACE="$(NAME)"; \
		echo "Generating Terraform execution plan for $(NAME)..."; \
		terraform plan $(TF_VAR_ARGS); \
		echo "Applying Terraform configuration for $(NAME)..."; \
		terraform apply -auto-approve $(TF_VAR_ARGS)'

# One shell: load RHCS + AWS credentials, then full destroy flow (creds stay in memory only).
_destroy: check-name _workspace
	@bash -c 'set -euo pipefail; \
		source "$(CURDIR)/scripts/load-creds.sh"; \
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
