#!/usr/bin/env bash
# Remove leftover ROSA-managed resources that block VPC deletion.
# Terraform does not manage these (e.g. *-vpce-private-router security groups).
# Honors TF_WORKSPACE (set by Makefile) so multi-cluster state stays isolated.
set -euo pipefail

REGION="${AWS_REGION:-}"
VPC_ID="${VPC_ID:-}"

if [[ -n "${TF_WORKSPACE:-}" ]]; then
  echo "Using Terraform workspace: ${TF_WORKSPACE}"
fi

if [[ -z "${REGION}" && -f terraform.tfvars ]]; then
  REGION="$(awk -F'"' '/^aws_region/ {print $2; exit}' terraform.tfvars || true)"
fi
REGION="${REGION:-us-east-1}"

# Resolve state file for the active workspace (local backend).
state_file="terraform.tfstate"
if [[ -n "${TF_WORKSPACE:-}" && "${TF_WORKSPACE}" != "default" ]]; then
  state_file="terraform.tfstate.d/${TF_WORKSPACE}/terraform.tfstate"
fi

if [[ -z "${VPC_ID}" && -f "${state_file}" ]]; then
  VPC_ID="$(python3 - "${state_file}" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
for resource in data.get("resources", []):
    if resource.get("type") == "aws_vpc" and resource.get("name") == "vpc":
        for inst in resource.get("instances", []):
            vpc_id = (inst.get("attributes") or {}).get("id")
            if vpc_id:
                print(vpc_id)
                raise SystemExit(0)
raise SystemExit(0)
PY
)"
fi

if [[ -z "${VPC_ID}" ]]; then
  echo "No VPC found in Terraform state (${state_file}); nothing to clean."
  exit 0
fi

if ! aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --region "${REGION}" >/dev/null 2>&1; then
  echo "VPC ${VPC_ID} not found in ${REGION}; nothing to clean."
  exit 0
fi

echo "Cleaning orphaned ROSA resources in VPC ${VPC_ID} (${REGION})..."

delete_enis() {
  local eni attachment itype desc
  for eni in $(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --region "${REGION}" --output text); do
    [[ -z "${eni}" || "${eni}" == "None" ]] && continue
    itype="$(aws ec2 describe-network-interfaces \
      --network-interface-ids "${eni}" \
      --query 'NetworkInterfaces[0].InterfaceType' \
      --region "${REGION}" --output text 2>/dev/null || true)"
    desc="$(aws ec2 describe-network-interfaces \
      --network-interface-ids "${eni}" \
      --query 'NetworkInterfaces[0].Description' \
      --region "${REGION}" --output text 2>/dev/null || true)"
    # NAT / NLB / GWLB ENIs are AWS-managed (ela-attach) and belong to Terraform.
    case "${itype}" in
      nat_gateway|network_load_balancer|gateway_load_balancer) continue ;;
    esac
    if [[ "${desc}" == *"NAT Gateway"* ]]; then
      continue
    fi
    echo "  deleting ENI ${eni} (${itype})"
    attachment="$(aws ec2 describe-network-interfaces \
      --network-interface-ids "${eni}" \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
      --region "${REGION}" --output text 2>/dev/null || true)"
    if [[ -n "${attachment}" && "${attachment}" != "None" ]]; then
      aws ec2 detach-network-interface --attachment-id "${attachment}" --force --region "${REGION}" >/dev/null || true
      sleep 3
    fi
    aws ec2 delete-network-interface --network-interface-id "${eni}" --region "${REGION}" >/dev/null || true
  done
}

delete_security_groups() {
  local sg direction query revoke perms
  for sg in $(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --region "${REGION}" --output text); do
    [[ -z "${sg}" || "${sg}" == "None" ]] && continue
    echo "  revoking rules and deleting SG ${sg}"
    for direction in ingress egress; do
      query='SecurityGroups[0].IpPermissions'
      revoke="revoke-security-group-ingress"
      if [[ "${direction}" == "egress" ]]; then
        query='SecurityGroups[0].IpPermissionsEgress'
        revoke="revoke-security-group-egress"
      fi
      perms="$(aws ec2 describe-security-groups \
        --group-ids "${sg}" \
        --query "${query}" \
        --region "${REGION}" --output json)"
      if [[ -n "${perms}" && "${perms}" != "[]" && "${perms}" != "null" ]]; then
        aws ec2 "${revoke}" --group-id "${sg}" --ip-permissions "${perms}" --region "${REGION}" >/dev/null 2>&1 || true
      fi
    done
    if ! aws ec2 delete-security-group --group-id "${sg}" --region "${REGION}" >/dev/null 2>&1; then
      echo "  warning: could not delete SG ${sg} yet (may still be in use)"
      return 1
    fi
    echo "  deleted SG ${sg}"
  done
  return 0
}

# Retry: ENIs/SGs from ROSA can take a moment to become deletable after cluster destroy.
for attempt in 1 2 3 4 5; do
  delete_enis
  if delete_security_groups; then
    echo "Orphan cleanup done."
    exit 0
  fi
  echo "  retry ${attempt}/5 in 10s..."
  sleep 10
done

echo "warning: some orphaned security groups may still remain in ${VPC_ID}"
exit 0
