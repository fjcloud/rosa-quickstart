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
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
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

# RDS Oracle Database for Dev/Test
resource "random_password" "oracle_password" {
  length           = 16
  special          = false
  upper            = true
  lower            = true
  numeric          = true
  override_special = "!@#$%"
}

resource "aws_db_subnet_group" "oracle" {
  name       = "${var.cluster_name}-oracle-subnet-group"
  subnet_ids = module.vpc.private_subnets

  tags = var.global_tags
}

resource "aws_security_group" "oracle" {
  name_prefix = "${var.cluster_name}-oracle-sg"
  vpc_id      = module.vpc.vpc_id

  # Allow Oracle port from entire VPC CIDR (all nodes in the VPC)
  ingress {
    from_port   = 1521
    to_port     = 1521
    protocol    = "tcp"
    cidr_blocks = [module.vpc.cidr_block]
    description = "Oracle access from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.global_tags
}

resource "aws_db_instance" "oracle" {
  identifier = "${var.cluster_name}-oracle"

  # Oracle configuration based on your example
  engine         = "oracle-se2"
  engine_version = "19.0.0.0.ru-2025-04.rur-2025-04.r1"
  instance_class = "db.m5.large"
  license_model  = "license-included"

  # Storage configuration
  allocated_storage     = 200
  max_allocated_storage = 1000
  storage_type          = "gp3"
  storage_encrypted     = true
  iops                  = 12000
  storage_throughput    = 500

  # Credentials
  username = "admin"
  password = random_password.oracle_password.result

  # Network configuration
  db_subnet_group_name   = aws_db_subnet_group.oracle.name
  vpc_security_group_ids = [aws_security_group.oracle.id]
  publicly_accessible    = false

  # Parameter group
  parameter_group_name = aws_db_parameter_group.oracle.name

  # Backup and maintenance
  backup_retention_period    = 7
  backup_window              = "08:46-09:16"
  maintenance_window         = "sat:05:45-sat:06:15"
  auto_minor_version_upgrade = true

  # Performance insights
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  # Monitoring
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  # Deletion protection for dev/test
  deletion_protection = false

  # Skip final snapshot for dev/test
  skip_final_snapshot = true

  # Character sets
  character_set_name = "AL32UTF8"

  # Copy tags to snapshots
  copy_tags_to_snapshot = true

  tags = merge(var.global_tags, {
    Name        = "${var.cluster_name}-oracle-db"
    Environment = "dev-test"
  })

  depends_on = [module.vpc]
}

# Custom Oracle Parameter Group
resource "aws_db_parameter_group" "oracle" {
  family = "oracle-se2-19"
  name   = "${var.cluster_name}-oracle-params"

  parameter {
    name  = "nls_length_semantics"
    value = "CHAR"
  }

  parameter {
    name  = "open_cursors"
    value = "1000"
  }

  parameter {
    name  = "cursor_sharing"
    value = "FORCE"
  }

  tags = var.global_tags
}

# IAM role for RDS monitoring
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.cluster_name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = var.global_tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# Outputs - Only oc login command
output "oc_login_command" {
  description = "OC login command for the cluster"
  value       = "oc login ${module.rosa_cluster_hcp.cluster_api_url} -u ${module.rosa_cluster_hcp.cluster_admin_username} -p ${module.rosa_cluster_hcp.cluster_admin_password}"
  sensitive   = true
}

# Oracle Database Outputs
output "oracle_endpoint" {
  description = "Oracle database endpoint"
  value       = aws_db_instance.oracle.endpoint
}

output "oracle_port" {
  description = "Oracle database port"
  value       = aws_db_instance.oracle.port
}

output "oracle_username" {
  description = "Oracle database username"
  value       = aws_db_instance.oracle.username
}

output "oracle_password" {
  description = "Oracle database password"
  value       = random_password.oracle_password.result
  sensitive   = true
}

output "oracle_connection_string" {
  description = "Oracle database connection string"
  value       = "oracle://${aws_db_instance.oracle.username}:${random_password.oracle_password.result}@${aws_db_instance.oracle.endpoint}:${aws_db_instance.oracle.port}/DATABASE"
  sensitive   = true
}

output "oracle_status" {
  description = "Oracle database status"
  value       = aws_db_instance.oracle.status
}