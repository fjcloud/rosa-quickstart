.PHONY: deploy clean _init _plan _apply _destroy _fmt _validate _output help

# Default target
help:
	@echo "Available targets:"
	@echo "  deploy   - Complete deployment workflow (init → plan → apply → output credentials)"
	@echo "  clean    - Complete cleanup workflow (destroy → clean terraform files)"
	@echo "  help     - Show this help message"

# Complete deployment workflow
deploy: _init _fmt _validate _plan _apply

# Complete cleanup workflow  
clean: _destroy _clean-files

# Subtasks (internal use)
_init:
	@echo "🔧 Initializing Terraform..."
	@terraform init

_fmt:
	@echo "📝 Formatting Terraform files..."
	@terraform fmt -recursive

_validate:
	@echo "✅ Validating Terraform configuration..."
	@terraform validate

_plan:
	@echo "📋 Generating Terraform execution plan..."
	@terraform plan

_apply:
	@echo "🚀 Applying Terraform configuration..."
	@terraform apply -auto-approve

_destroy:
	@echo "💥 Destroying Terraform infrastructure..."
	@terraform destroy

_clean-files:
	@echo "🧹 Cleaning up Terraform files..."
	@rm -rf .terraform/
	@rm -f .terraform.lock.hcl
	@rm -f terraform.tfstate*
	@rm -f *.tfplan
	@echo "✨ Cleanup completed!"
