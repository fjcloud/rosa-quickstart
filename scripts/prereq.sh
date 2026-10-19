#!/usr/bin/env bash
# Prepare a fresh AWS account for `make deploy`.
# Links the account to the Red Hat org, checks ROSA HCP quota, installs
# Terraform when it is missing, and writes terraform.tfvars when absent.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
export AWS_PAGER=""
export PATH="${HOME}/.local/bin:${PATH}"

# shellcheck disable=SC1091
source "${root}/scripts/load-creds.sh"

install_bin() {
  local dest="/usr/local/bin"
  if [[ ! -w "${dest}" ]]; then
    dest="${HOME}/.local/bin"
    mkdir -p "${dest}"
  fi
  install -m 755 "$1" "${dest}/$(basename "$1")"
  echo "Installed $(basename "$1") to ${dest}"
}

if ! command -v terraform >/dev/null 2>&1; then
  echo "Installing Terraform..."
  ver="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform | python3 -c 'import json,sys; print(json.load(sys.stdin)["current_version"])')"
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL "https://releases.hashicorp.com/terraform/${ver}/terraform_${ver}_linux_${arch}.zip" -o "${tmp}/terraform.zip"
  python3 -m zipfile -e "${tmp}/terraform.zip" "${tmp}"
  install_bin "${tmp}/terraform"
  rm -rf "${tmp}"
fi

if ! command -v rosa >/dev/null 2>&1; then
  if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "Error: rosa is not on PATH. Install it from https://mirror.openshift.com/pub/openshift-v4/clients/rosa/latest/" >&2
    exit 1
  fi
  echo "Installing the ROSA CLI..."
  tmp="$(mktemp -d)"
  curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/rosa/latest/rosa-linux.tar.gz -o "${tmp}/rosa.tar.gz"
  tar --no-same-owner -C "${tmp}" -xzf "${tmp}/rosa.tar.gz" rosa
  install_bin "${tmp}/rosa"
  rm -rf "${tmp}"
fi

if ! command -v oc >/dev/null 2>&1; then
  echo "Installing oc..."
  case "$(uname -m)" in
    x86_64) oc_archive=openshift-client-linux.tar.gz ;;
    aarch64|arm64) oc_archive=openshift-client-linux-arm64.tar.gz ;;
    *) echo "Error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/${oc_archive}" -o "${tmp}/oc.tar.gz"
  tar --no-same-owner -C "${tmp}" -xzf "${tmp}/oc.tar.gz" oc
  install_bin "${tmp}/oc"
  rm -rf "${tmp}"
fi

echo "Signing in to Red Hat OpenShift Cluster Manager..."
if [[ -n "${RHCS_TOKEN:-}" ]]; then
  rosa login --token "${RHCS_TOKEN}"
else
  rosa login --client-id "${RHCS_CLIENT_ID}" --client-secret "${RHCS_CLIENT_SECRET}"
fi

account="$(aws sts get-caller-identity --query Account --output text)"
region="${AWS_DEFAULT_REGION:-${AWS_REGION:-}}"
if [[ -z "${region}" ]]; then
  region="$(aws configure get region || true)"
fi
region="${region:-us-east-2}"
export AWS_DEFAULT_REGION="${region}"
echo "AWS account ${account}, region ${region}"

ensure_role() {
  local kind="$1"
  shift
  local output
  if ! output="$("$@" 2>&1)"; then
    if ! grep -Eqi 'already exists|AlreadyExists' <<<"${output}"; then
      printf '%s\n' "${output}" >&2
      exit 1
    fi
  fi
  printf '%s\n' "${output}"
}

echo "Ensuring the OpenShift Cluster Manager role and the user role exist..."
ensure_role ocm rosa create ocm-role --mode auto --admin --prefix ManagedOpenShift --yes
ensure_role user rosa create user-role --mode auto --prefix ManagedOpenShift --yes

link_roles() {
  local label="$1" list_name="$2" link_name="$3"
  rosa list "${list_name}" -o json > /tmp/rosa-roles.json
  local status=0
  python3 - <<'PY' || status=$?
import json, sys
data = json.load(open("/tmp/rosa-roles.json"))
if isinstance(data, dict):
    data = data.get("items") or data.get("roles") or []
rows = []
for item in data:
    if not isinstance(item, dict):
        continue
    arn = (
        item.get("Role ARN")
        or item.get("OCM Role ARN")
        or item.get("User Role ARN")
        or item.get("RoleARN")
        or item.get("role_arn")
        or item.get("arn")
        or ""
    )
    linked = str(item.get("Linked") or item.get("linked") or "")
    admin = str(item.get("Admin") or item.get("admin") or "")
    if arn:
        rows.append((admin.lower() in {"yes", "true"}, linked.lower() in {"yes", "true"}, arn))
if not rows:
    sys.exit(2)
rows.sort(key=lambda row: (not row[0], not row[1]))
open("/tmp/rosa-role-pick", "w").write(("link\n" if not rows[0][1] else "ok\n") + rows[0][2] + "\n")
PY
  if [[ "${status}" -ne 0 ]]; then
    if [[ "${status}" -eq 2 ]]; then
      echo "Error: no ${label} role was found in account ${account}." >&2
    else
      echo "Error: could not read ${label} roles (exit ${status})." >&2
    fi
    exit 1
  fi
  local action arn
  action="$(sed -n '1p' /tmp/rosa-role-pick)"
  arn="$(sed -n '2p' /tmp/rosa-role-pick)"
  rm -f /tmp/rosa-roles.json /tmp/rosa-role-pick
  if [[ "${action}" == "ok" ]]; then
    echo "${label} role is already linked."
    return
  fi
  echo "Linking ${label} role..."
  local link_out
  if ! link_out="$(rosa link "${link_name}" --role-arn "${arn}" --yes 2>&1)"; then
    if ! grep -Eqi 'already linked|already associated' <<<"${link_out}"; then
      printf '%s\n' "${link_out}" >&2
      exit 1
    fi
  fi
  printf '%s\n' "${link_out}"
}

link_roles OCM ocm-roles ocm-role
link_roles user user-roles user-role

echo "Ensuring the load balancer service-linked role exists..."
slr_out="$(aws iam create-service-linked-role --aws-service-name elasticloadbalancing.amazonaws.com 2>&1 || true)"
if grep -Eqi 'has been taken|already exists|Service role name AWSServiceRoleForElasticLoadBalancing has been taken' <<<"${slr_out}"; then
  echo "Load balancer service-linked role already exists."
elif grep -Eq 'ARN' <<<"${slr_out}"; then
  echo "Created the load balancer service-linked role."
elif [[ -n "${slr_out}" ]]; then
  printf '%s\n' "${slr_out}" >&2
  exit 1
fi

if [[ ! -f terraform.tfvars ]]; then
  echo "Choosing a worker instance type offered in ${region}..."
  machine=""
  for candidate in m5.xlarge m6i.xlarge m7i.xlarge; do
    count="$(aws ec2 describe-instance-type-offerings --region "${region}" --location-type region --filters "Name=instance-type,Values=${candidate}" --query 'length(InstanceTypeOfferings)' --output text)"
    if [[ "${count}" != "0" && "${count}" != "None" ]]; then
      machine="${candidate}"
      break
    fi
  done
  if [[ -z "${machine}" ]]; then
    echo "Error: none of m5.xlarge, m6i.xlarge, or m7i.xlarge are offered in ${region}." >&2
    exit 1
  fi
  version="$(rosa list versions --hosted-cp --channel-group stable -o json | python3 -c '
import json, sys
items = json.load(sys.stdin)
default = [item["raw_id"] for item in items if item.get("hosted_control_plane_default")]
print(default[0] if default else items[0]["raw_id"])
')"
  cat > terraform.tfvars <<EOF
# Written by scripts/prereq.sh. One zone and two workers is the smallest ROSA HCP cluster.
cluster_name             = "rosa-ai"
aws_region               = "${region}"
vpc_cidr                 = "10.10.0.0/16"
availability_zones_count = 1
replicas                 = 2
compute_machine_type     = "${machine}"
private                  = false
openshift_version        = "${version}"
EOF
  echo "Wrote terraform.tfvars (${machine}, OpenShift ${version}, ${region})."
fi

tf_value() {
  local key="$1" fallback="$2" line
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" terraform.tfvars | tail -1 || true)"
  if [[ -z "${line}" ]]; then
    printf '%s\n' "${fallback}"
    return
  fi
  python3 -c 'import sys
val = sys.argv[1].split("=", 1)[1].strip().split("#", 1)[0].strip().strip("\"")
print(val)' "${line}"
}

az_count="$(tf_value availability_zones_count 3)"
replicas="$(tf_value replicas "")"
machine="$(tf_value compute_machine_type m7i.xlarge)"
region="$(tf_value aws_region "${region}")"
if [[ -z "${replicas}" ]]; then
  if [[ "${az_count}" -lt 2 ]]; then
    replicas=2
  else
    replicas="${az_count}"
  fi
fi
vcpus="$(aws ec2 describe-instance-types --region "${region}" --instance-types "${machine}" --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text)"
need_vcpu=$((replicas * vcpus))

require_quota() {
  local code="$1" need="$2" label="$3" have
  if ! have="$(aws service-quotas get-service-quota --region "${region}" --service-code ec2 --quota-code "${code}" --query 'Quota.Value' --output text 2>/tmp/quota.err)"; then
    echo "Could not read EC2 quota ${code} (${label}). Check Service Quotas in ${region}." >&2
    cat /tmp/quota.err >&2
    exit 1
  fi
  python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) + 1e-6 >= float(sys.argv[2]) else 1)' "${have}" "${need}" || {
    echo "Error: ${label} in ${region} is ${have}; this cluster needs ${need}." >&2
    echo "Request a higher quota, then run make prereq again:" >&2
    echo "  aws service-quotas request-service-quota-increase --service-code ec2 --quota-code ${code} --desired-value ${need} --region ${region}" >&2
    exit 1
  }
  echo "${label}: ${have} available, ${need} required."
}

echo "Checking quota for ${replicas} ${machine} workers in ${az_count} zone(s)..."
require_quota L-1216C47A "${need_vcpu}" "Standard On-Demand vCPUs"
require_quota L-FE5A380F 1 "NAT gateways per Availability Zone"
require_quota L-0263D0A3 "${az_count}" "VPC Elastic IP addresses"
require_quota L-F678F1CE 1 "VPCs per Region"

echo "Prerequisites are ready. Deploy with: make deploy NAME=<name>"
