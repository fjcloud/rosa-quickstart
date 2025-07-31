# ROSA HCP Cluster Terraform

Deploy a Red Hat OpenShift Service on AWS (ROSA) Hosted Control Plane (HCP) cluster using Terraform.

## Prerequisites

- AWS CLI configured
- Terraform >= 1.0
- OpenShift CLI (oc)
- Red Hat Cloud Services (RHCS) service account

## Authentication

1. **Create a service account:**
   - Go to [Red Hat Cloud Services Console](https://console.redhat.com/iam/service-accounts)
   - Create a new service account with appropriate permissions

2. **Export environment variables:**
   ```bash
   export RHCS_CLIENT_ID="your-client-id-here"
   export RHCS_CLIENT_SECRET="your-client-secret-here"
   ```

## Quick Start

1. **Copy the example configuration:**
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. **Edit the configuration:**
   ```bash
   vim terraform.tfvars
   ```

3. **Deploy the cluster:**
   ```bash
   make deploy
   ```

4. **Connect to the cluster:**
   ```bash
   $(terraform output -raw oc_login_command)
   ```

## Cleanup

```bash
make clean
```

## Variables

- `cluster_name`: Name of the ROSA cluster
- `aws_region`: AWS region for deployment
- `global_tags`: Global tags applied to all resources (optional)
- `vpc_cidr`: CIDR block for VPC
- `availability_zones_count`: Number of availability zones
- `openshift_version`: OpenShift version to deploy 