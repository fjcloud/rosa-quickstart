#!/usr/bin/env python3
"""Check whether the Red Hat organization has an OCM role for the AWS account."""

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.openshift.com/api/accounts_mgmt/v1"


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
                raise PrerequisiteError("The Red Hat API response is too large.")
            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise PrerequisiteError("The Red Hat API response is invalid.")
            return payload
    except urllib.error.HTTPError as error:
        error.close()
        if allow_missing and error.code == 404:
            return {}
        raise PrerequisiteError(
            f"Cannot verify the OCM role (HTTP {error.code})."
        ) from None
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise PrerequisiteError("Cannot read the OCM role status.") from None


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


def output(command, failure):
    try:
        return subprocess.check_output(command, stderr=subprocess.DEVNULL, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        raise PrerequisiteError(failure) from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("aws_account", help="AWS infrastructure account ID")
    args = parser.parse_args()
    try:
        token = output(["rosa", "token"], "Cannot obtain a Red Hat access token. Run rosa login first.")
        if not token:
            raise PrerequisiteError("Red Hat did not return an access token.")
        print("OCM role already linked: " + check_ocm_role(args.aws_account, token))
    except MissingOCMRole as error:
        print(str(error))
        return 3
    except PrerequisiteError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
