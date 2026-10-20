# ROSA HCP Cluster Terraform

Deploy a Red Hat OpenShift Service on AWS (ROSA) Hosted Control Plane (HCP) cluster using Terraform.

Supports **multiple clusters** at once: each `NAME` gets its own Terraform workspace and state.

## Prerequisites

- AWS CLI credentials in the environment, or a working `aws` profile. The workshop shell is already signed in. `/usr/local/bin/auth-aws` is only a fallback for a Red Hat employee shell that has no AWS credentials yet.
- Terraform >= 1.0, the ROSA CLI, and `oc`. `make prereq` installs Terraform when it is missing, and installs `rosa` and `oc` on x86_64 when they are missing.
- A Red Hat Cloud Services service account (or `RHCS_TOKEN`)
- A ROSA HCP Marketplace billing account linked to the **same Red Hat organization** as that identity. The billing account can differ from the AWS account hosting the cluster. The organizer completes the association through the [AWS ROSA console](https://console.aws.amazon.com/rosa/home#/get-started) and **Continue to Red Hat → Connect accounts**. A successful `rosa whoami` or an OCM IAM role link alone does not satisfy this prerequisite.

## Authentication

1. **Create a service account:**
   - Go to [Red Hat Cloud Services Console](https://console.redhat.com/iam/service-accounts)
   - Create a new service account
   
2. **Create `.env` with RHCS credentials:**
   ```bash
   cat > .env <<'EOF'
   export RHCS_CLIENT_ID="your-client-id-here"
   export RHCS_CLIENT_SECRET="your-client-secret-here"
   EOF
   ```

3. **Billing, IAM roles and quota:** `make prereq` signs in with the service account and preserves an existing OCM role association. If one is missing, it runs `rosa create ocm-role --no-console --mode auto --prefix CloudTerminal --yes`. It then checks the selected billing account against the Red Hat organization's eligible ROSA HCP billing accounts. Missing Marketplace linking stops deployment before Terraform creates network or cluster resources. After that check it prepares the load-balancer service-linked role and checks vCPU, NAT, Elastic IP, and VPC quota. When `terraform.tfvars` is missing it writes one for the current AWS region: one availability zone and two workers, which is the smallest ROSA HCP cluster.

4. **Credentials on deploy/clean:** `make deploy` runs `make prereq`, then sources `.env` in-process. It uses AWS credentials already in the shell. It calls `auth-aws` only when those credentials are absent. Overrides: `DOTENV=...`, `AUTH_AWS=...`.

`.env` and `terraform.tfvars` are gitignored. Never put RHCS secrets, AWS keys, or kubeconfigs in this repo.

## Quick Start

1. **Copy the example configuration:**
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. **Edit the configuration** (region, tags, version, etc.):
   ```bash
   vim terraform.tfvars
   ```

   `cluster_name` in `terraform.tfvars` is overridden by `NAME=` on the command line.

3. **Deploy a cluster** (`NAME` is required). This runs `make prereq` first:
   ```bash
   make deploy NAME=fja-hcp1
   ```

   By default, the cluster's AWS account also pays for ROSA HCP. If your organizer supplies a different eligible payer, use `make deploy NAME=fja-hcp1 BILLING_ACCOUNT_ID=123456789012`, or set `aws_billing_account_id` in `terraform.tfvars`. The prerequisite check and Terraform use the same selection. An AWS Organizations management account is not automatically an eligible ROSA payer.

4. **Connect to the cluster:**
   ```bash
   $(make output NAME=fja-hcp1)
   ```

## Multiple clusters

Each `NAME` uses a separate Terraform workspace (`terraform.tfstate.d/<name>/`), so you can deploy several clusters independently:

```bash
make deploy NAME=fja-hcp1
make deploy NAME=fja-hcp2   # safe from another shell in parallel
make list
make output NAME=fja-hcp1
make clean NAME=fja-hcp1    # only destroys fja-hcp1
```

- `NAME` must be a valid ROSA cluster name: lowercase, start with a letter, max 15 characters (`[a-z0-9-]`).
- Do not run two makes against the **same** `NAME` at once.
- Shared settings (region, tags, OpenShift version, VPC CIDR) come from `terraform.tfvars`; only the cluster name is overridden per deploy.

## Cleanup

```bash
make clean NAME=fja-hcp1
```

`make clean` destroys the ROSA cluster first, then runs `cleanup_vpc_orphans.sh` to remove leftover Red Hat–managed security groups/ENIs (e.g. `*-vpce-private-router`) that are not in Terraform state, then destroys the VPC and remaining resources, then deletes that workspace. Without the orphan cleanup step, VPC deletion often fails with `DependencyViolation`.

The orphan script skips Terraform-managed NAT/NLB ENIs (`ela-attach`); those are removed when Terraform destroys the NAT gateways. Do not export `TF_WORKSPACE` in your shell while running `make clean`, or workspace deletion can fail because Terraform will not delete the active workspace.

## Makefile targets

| Target | Description |
|--------|-------------|
| `make prereq` | tools, OCM role, Marketplace billing check, quota, default `terraform.tfvars` |
| `make deploy NAME=<name>` | prereq → init → plan → apply → print oc login |
| `make clean NAME=<name>` | destroy cluster + VPC orphans + workspace |
| `make output NAME=<name>` | print oc login command |
| `make list` | list cluster workspaces |
| `make help` | show help |

## Variables

- `cluster_name`: Name of the ROSA cluster (set via `NAME=` for make targets)
- `aws_region`: AWS region for deployment
- `aws_billing_account_id`: Eligible ROSA HCP billing account; defaults to the infrastructure account. `BILLING_ACCOUNT_ID` overrides it for Make targets.
- `global_tags`: Global tags applied to all resources (optional)
- `vpc_cidr`: CIDR block for VPC
- `availability_zones_count`: Number of availability zones
- `replicas`: Worker count. Defaults to 2 for one AZ, otherwise one per AZ
- `compute_machine_type`: Worker instance type (`m7i.xlarge` by default)
- `openshift_version`: OpenShift version to deploy (default `4.22.18`, the current hosted control plane default)
- `private`: Cluster private (false by default)
- `no_cni`: Skip the default OVN-Kubernetes CNI (`false` by default). Same as `rosa create cluster --hosted-cp --no-cni`. Requires provider `rhcs` >= 1.7.8, which sets cluster network type to `Other`. Worker nodes stay `NotReady` until you install a CNI. Override on the command line with `make deploy NAME=<name> NO_CNI=true`. Cannot be changed after the cluster is created.
