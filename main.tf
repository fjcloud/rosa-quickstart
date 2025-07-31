terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.38.0"
    }
    rhcs = {
      source  = "terraform-redhat/rhcs"
      version = ">= 1.6.5"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
  required_version = ">= 1.0"
}

provider "aws" {
  region = var.aws_region
}

provider "rhcs" {
  # Configuration will be read from environment variables:
  # RHCS_TOKEN (for token authentication)
  # OR
  # RHCS_CLIENT_ID and RHCS_CLIENT_SECRET (for service account authentication)
}

# Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-3"
}

variable "cluster_name" {
  description = "Name of the ROSA cluster"
  type        = string
  default     = "my-cluster"
}

variable "openshift_version" {
  description = "OpenShift version"
  type        = string
  default     = "4.19.3"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "availability_zones_count" {
  description = "Number of availability zones to use"
  type        = number
  default     = 3
}

variable "global_tags" {
  description = "Global tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# VPC Module
module "vpc" {
  source  = "terraform-redhat/rosa-hcp/rhcs//modules/vpc"
  version = "1.6.5"

  name_prefix              = var.cluster_name
  availability_zones_count = var.availability_zones_count
  vpc_cidr                 = var.vpc_cidr

  tags = var.global_tags
}

# Account Roles Module
module "account_roles" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/account-iam-resources"

  account_role_prefix = "${var.cluster_name}-account"

  tags = var.global_tags
}

# OIDC Config Module
module "oidc_config" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/oidc-config-and-provider"

  tags = var.global_tags

  depends_on = [module.account_roles]
}

# Operator Roles Module
module "operator_roles" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/operator-roles"

  operator_role_prefix = "${var.cluster_name}-operator"
  oidc_endpoint_url    = module.oidc_config.oidc_endpoint_url

  tags = var.global_tags

  depends_on = [module.account_roles, module.oidc_config]
}

# ROSA HCP Cluster
module "rosa_cluster_hcp" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/rosa-cluster-hcp"

  cluster_name         = var.cluster_name
  openshift_version    = var.openshift_version
  operator_role_prefix = module.operator_roles.operator_role_prefix
  oidc_config_id       = module.oidc_config.oidc_config_id

  # IAM roles
  installer_role_arn = module.account_roles.account_roles_arn["HCP-ROSA-Installer"]
  support_role_arn   = module.account_roles.account_roles_arn["HCP-ROSA-Support"]
  worker_role_arn    = module.account_roles.account_roles_arn["HCP-ROSA-Worker"]

  # Network configuration
  machine_cidr           = module.vpc.cidr_block
  aws_subnet_ids         = concat(module.vpc.public_subnets, module.vpc.private_subnets)
  aws_availability_zones = module.vpc.availability_zones

  # Compute configuration
  replicas             = var.availability_zones_count
  compute_machine_type = "m7i.xlarge"

  # Create admin user with auto-generated password
  create_admin_user = true

  tags = var.global_tags

  depends_on = [
    module.vpc,
    module.account_roles,
    module.oidc_config,
    module.operator_roles
  ]
}

# Outputs - Only oc login command
output "oc_login_command" {
  description = "OC login command for the cluster"
  value       = "oc login ${module.rosa_cluster_hcp.cluster_api_url} -u ${module.rosa_cluster_hcp.cluster_admin_username} -p ${module.rosa_cluster_hcp.cluster_admin_password}"
  sensitive   = true
}