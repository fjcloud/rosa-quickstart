# ROSA HCP Cluster Terraform

Deploy a Red Hat OpenShift Service on AWS (ROSA) Hosted Control Plane (HCP) cluster using Terraform.

Supports **multiple clusters** at once: each `NAME` gets its own Terraform workspace and state.

## Prerequisites

- AWS CLI configured
- Terraform >= 1.0
- OpenShift CLI (oc)
- Red Hat Cloud Services (RHCS) service account

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

3. **Credentials on deploy/clean:** `make deploy` / `make clean` source `.env` and `/usr/local/bin/auth-aws` in-process (not copied elsewhere). Overrides: `DOTENV=...`, `AUTH_AWS=...`. Kerberos/`kinit` must already be valid for `auth-aws`.

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

3. **Deploy a cluster** (`NAME` is required):
   ```bash
   make deploy NAME=fja-hcp1
   ```

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
| `make deploy NAME=<name>` | init → plan → apply → print oc login |
| `make clean NAME=<name>` | destroy cluster + VPC orphans + workspace |
| `make output NAME=<name>` | print oc login command |
| `make list` | list cluster workspaces |
| `make help` | show help |

## Variables

- `cluster_name`: Name of the ROSA cluster (set via `NAME=` for make targets)
- `aws_region`: AWS region for deployment
- `global_tags`: Global tags applied to all resources (optional)
- `vpc_cidr`: CIDR block for VPC
- `availability_zones_count`: Number of availability zones
- `openshift_version`: OpenShift version to deploy
- `private`: Cluster private (false by default)
