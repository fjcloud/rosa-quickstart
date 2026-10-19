# Source this file. It loads Red Hat Cloud Services credentials and AWS
# credentials into the current shell. It does not print secrets.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "Source this file: source scripts/load-creds.sh" >&2
  exit 1
fi

dotenv="${DOTENV:-.env}"
if [[ -f "${dotenv}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${dotenv}"
  set +a
fi

if [[ -z "${RHCS_TOKEN:-}" && ( -z "${RHCS_CLIENT_ID:-}" || -z "${RHCS_CLIENT_SECRET:-}" ) ]]; then
  echo "Error: set RHCS_CLIENT_ID and RHCS_CLIENT_SECRET in ${dotenv}, or export RHCS_TOKEN." >&2
  echo "Create a service account at https://console.redhat.com/iam/service-accounts" >&2
  return 1
fi

if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || aws sts get-caller-identity >/dev/null 2>&1; then
  echo "Using the AWS credentials already configured in this shell."
else
  auth_aws="${AUTH_AWS:-/usr/local/bin/auth-aws}"
  if [[ ! -f "${auth_aws}" ]]; then
    echo "Error: AWS credentials are not configured, and ${auth_aws} is not available." >&2
    echo "Export AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_DEFAULT_REGION, then run this again." >&2
    return 1
  fi
  echo "Refreshing AWS credentials via ${auth_aws}."
  # shellcheck disable=SC1090
  source "${auth_aws}"
fi
