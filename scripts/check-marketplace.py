#!/usr/bin/env python3
"""Check the same ROSA HCP billing quota used by the ROSA CLI, without mutations."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.openshift.com/api/accounts_mgmt/v1"
QUOTA = "cluster|byoc|moa|marketplace"


class PrerequisiteError(Exception):
    pass


class MissingOCMRole(PrerequisiteError):
    pass


def read_json(path, token, allow_missing=False):
    request = urllib.request.Request(
        API + path,
        headers={"Authorization": "Bearer " + token, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read(2_000_001)
            if len(raw) > 2_000_000:
                raise PrerequisiteError("The Red Hat billing response is too large.")
            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise PrerequisiteError("The Red Hat billing response is invalid.")
            return payload
    except urllib.error.HTTPError as error:
        error.close()
        if allow_missing and error.code == 404:
            return {}
        raise PrerequisiteError(
            f"Cannot verify Red Hat Marketplace billing (HTTP {error.code})."
        ) from None
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise PrerequisiteError("Cannot read Red Hat Marketplace billing status.") from None


def check_billing(account, token):
    if not re.fullmatch(r"[0-9]{12}", account):
        raise PrerequisiteError("A valid 12-digit AWS billing account ID is required.")
    current = read_json("/current_account", token)
    organization = current.get("organization", {}).get("id", "")
    if not organization:
        raise PrerequisiteError("The current Red Hat identity has no organization.")
    for page in range(1, 101):
        query = urllib.parse.urlencode(
            {"search": f"quota_id='{QUOTA}'", "fetchCloudAccounts": "true", "page": page, "size": 100}
        )
        payload = read_json(
            "/organizations/" + urllib.parse.quote(organization, safe="") + "/quota_cost?" + query,
            token,
        )
        items = payload.get("items")
        if not isinstance(items, list):
            raise PrerequisiteError("The Red Hat billing quota response is invalid.")
        for item in items:
            if item.get("quota_id") != QUOTA:
                continue
            for cloud in item.get("cloud_accounts", []):
                if cloud.get("cloud_provider_id") == "aws" and cloud.get("cloud_account_id") == account:
                    return organization
        if len(items) < 100:
            break
    else:
        raise PrerequisiteError("The Red Hat billing quota response exceeded the page limit.")
    raise PrerequisiteError(
        f"AWS billing account {account} is not linked to Red Hat organization {organization} "
        "for ROSA HCP in AWS Marketplace.\n"
        "An organizer must enable/subscribe to ROSA HCP in the selected billing account, then use "
        "'Continue to Red Hat' / 'Connect accounts' with this Red Hat organization: "
        "https://console.aws.amazon.com/rosa/home#/get-started\n"
        "An OCM IAM role link or a successful 'rosa whoami' does not complete Marketplace linking. "
        "After linking, rerun make prereq."
    )


def check_ocm_role(account, token):
    if not re.fullmatch(r"[0-9]{12}", account):
        raise PrerequisiteError("A valid 12-digit AWS infrastructure account ID is required.")
    organization = read_json("/current_account", token).get("organization", {}).get("id", "")
    if not organization:
        raise PrerequisiteError("The current Red Hat identity has no organization.")
    label = read_json("/organizations/" + urllib.parse.quote(organization, safe="") +
                      "/labels/sts_ocm_role", token, allow_missing=True)
    for role in label.get("value", "").split(","):
        if role.strip().startswith("arn:aws:iam::" + account + ":role/"):
            return role.strip()
    raise MissingOCMRole("No OCM role is linked for this AWS account; preparing one in auto mode.")


def configured_billing_account(directory=Path(".")):
    # Match Terraform's normal variable-file precedence. The Makefile's explicit
    # BILLING_ACCOUNT_ID becomes a -var argument and therefore takes precedence.
    value = os.environ.get("TF_VAR_aws_billing_account_id") or None
    paths = [directory / "terraform.tfvars", directory / "terraform.tfvars.json"]
    paths += sorted([*directory.glob("*.auto.tfvars"), *directory.glob("*.auto.tfvars.json")])
    for path in paths:
        if not path.exists():
            continue
        if path.suffix == ".json":
            try:
                values = json.loads(path.read_text())
                if "aws_billing_account_id" in values:
                    value = values["aws_billing_account_id"]
            except (ValueError, OSError):
                raise PrerequisiteError(f"Cannot read billing configuration in {path.name}.") from None
        else:
            text = re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.S)
            assignments = re.findall(r"(?m)^\s*aws_billing_account_id\s*=\s*([^\n]+)", text)
            if assignments:
                match = re.fullmatch(r'(?:(?:"([0-9]{12}|)")|([0-9]{12})|(null))\s*(?:(?:#|//).*)?', assignments[-1].strip())
                if not match:
                    raise PrerequisiteError(f"Use a literal 12-digit aws_billing_account_id in {path.name}.")
                value = match.group(1) or match.group(2)
    value = os.environ.get("BILLING_ACCOUNT_ID") or value
    if value is None or value == "":
        raise PrerequisiteError(
            "No ROSA billing account selected. Ask the organizer for the approved payer and set "
            "BILLING_ACCOUNT_ID=<12-digit-account> or aws_billing_account_id in terraform.tfvars. "
            "The lab account is never selected automatically."
        )
    value = str(value)
    if not re.fullmatch(r"[0-9]{12}", value):
        raise PrerequisiteError("BILLING_ACCOUNT_ID must be a 12-digit AWS account ID.")
    return value


def output(command, failure):
    try:
        return subprocess.check_output(command, stderr=subprocess.DEVNULL, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        raise PrerequisiteError(failure) from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aws-account", help="Infrastructure account for --ocm-role; defaults to the signed-in AWS account")
    parser.add_argument("--billing-account", help="Explicit billing account, otherwise use Terraform/Make configuration")
    parser.add_argument("--ocm-role", action="store_true", help="Check the infrastructure OCM role instead of billing")
    args = parser.parse_args()
    try:
        if args.ocm_role:
            account = args.aws_account or output(
                ["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"],
                "Cannot identify the AWS account. Sign in to the lab first.",
            )
        else:
            billing = args.billing_account if args.billing_account is not None else configured_billing_account()
            if not re.fullmatch(r"[0-9]{12}", billing):
                raise PrerequisiteError("A valid 12-digit AWS billing account ID is required.")
        token = output(["rosa", "token"], "Cannot obtain a Red Hat access token. Run rosa login first.")
        if not token:
            raise PrerequisiteError("Red Hat did not return an access token.")
        if args.ocm_role:
            print("OCM role already linked: " + check_ocm_role(account, token))
        else:
            organization = check_billing(billing, token)
            print(f"ROSA HCP Marketplace billing ready: AWS {billing}, Red Hat organization {organization}.")
    except MissingOCMRole as error:
        print(str(error))
        return 3
    except PrerequisiteError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
