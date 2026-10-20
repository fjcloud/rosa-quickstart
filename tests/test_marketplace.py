import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('marketplace', ROOT / 'scripts/check-marketplace.py')
marketplace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(marketplace)
LAB, PAYER, ORG = '111111111111', '222222222222', 'workshop-org'


class MarketplaceTests(unittest.TestCase):
    def request(self, request, timeout):
        self.assertEqual(request.get_method(), 'GET')
        self.assertEqual(request.get_header('Authorization'), 'Bearer test-token')
        if request.full_url.endswith('/current_account'):
            return io.BytesIO(json.dumps({'organization': {'id': ORG}}).encode())
        if '/quota_cost?' in request.full_url:
            self.assertIn('fetchCloudAccounts=true', request.full_url)
            return io.BytesIO(json.dumps({'items': [{'quota_id': marketplace.QUOTA,
                'cloud_accounts': [{'cloud_provider_id': 'aws', 'cloud_account_id': PAYER}]}]}).encode())
        if request.full_url.endswith('/labels/sts_ocm_role'):
            return io.BytesIO(json.dumps({'value': 'arn:aws:iam::'+LAB+':role/Existing'}).encode())
        self.fail('Unexpected endpoint')

    def test_payer_can_differ_from_infrastructure(self):
        with patch.object(marketplace.urllib.request, 'urlopen', side_effect=self.request):
            self.assertEqual(marketplace.check_billing(PAYER, 'test-token'), ORG)
            with self.assertRaises(marketplace.PrerequisiteError) as error:
                marketplace.check_billing(LAB, 'test-token')
            self.assertIn('not linked', str(error.exception))
            self.assertIn(LAB, str(error.exception))
            self.assertIn(ORG, str(error.exception))
            self.assertNotIn('test-token', str(error.exception))

    def test_existing_ocm_role_is_separate_from_billing(self):
        with patch.object(marketplace.urllib.request, 'urlopen', side_effect=self.request):
            self.assertIn(LAB, marketplace.check_ocm_role(LAB, 'test-token'))
            with self.assertRaises(marketplace.PrerequisiteError):
                marketplace.check_billing(LAB, 'test-token')

    def test_billing_eligibility_checks_all_pages(self):
        def request(req, timeout):
            if '/quota_cost?' in req.full_url and 'page=1&' in req.full_url:
                return io.BytesIO(json.dumps({'items': [{'quota_id': 'other'}] * 100}).encode())
            return self.request(req, timeout)
        with patch.object(marketplace.urllib.request, 'urlopen', side_effect=request) as calls:
            self.assertEqual(marketplace.check_billing(PAYER, 'test-token'), ORG)
            self.assertEqual(calls.call_count, 3)

    def test_api_failure_does_not_expose_response_or_token(self):
        error = urllib.error.HTTPError('https://example.test', 403, 'sensitive-upstream', {}, io.BytesIO(b'sensitive-body'))
        with patch.object(marketplace.urllib.request, 'urlopen', side_effect=error):
            with self.assertRaises(marketplace.PrerequisiteError) as result:
                marketplace.check_billing(LAB, 'test-token')
            self.assertIn('403', str(result.exception))
            self.assertNotIn('sensitive', str(result.exception))

    def test_billing_configuration_matches_make_and_file_precedence(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            directory = Path(tmp)
            with self.assertRaises(marketplace.PrerequisiteError):
                marketplace.configured_billing_account(directory)
            os.environ['TF_VAR_aws_billing_account_id'] = '333333333333'
            (directory / 'terraform.tfvars').write_text('aws_billing_account_id = "'+PAYER+'" # selected payer\n')
            self.assertEqual(marketplace.configured_billing_account(directory), PAYER)
            (directory / 'z.auto.tfvars.json').write_text(json.dumps({'aws_billing_account_id': '444444444444'}))
            self.assertEqual(marketplace.configured_billing_account(directory), '444444444444')
            os.environ['BILLING_ACCOUNT_ID'] = '555555555555'
            self.assertEqual(marketplace.configured_billing_account(directory), '555555555555')
            os.environ['BILLING_ACCOUNT_ID'] = 'invalid'
            with self.assertRaises(marketplace.PrerequisiteError):
                marketplace.configured_billing_account(directory)

    def test_null_and_commented_settings_do_not_select_a_payer(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            directory = Path(tmp)
            (directory / 'terraform.tfvars').write_text('/*\naws_billing_account_id = "'+PAYER+'"\n*/\naws_billing_account_id = null\n')
            with self.assertRaises(marketplace.PrerequisiteError):
                marketplace.configured_billing_account(directory)

    def test_cli_does_not_infer_billing_from_the_lab_or_call_cloud_apis(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for name in ['aws', 'rosa']:
                binary = directory / name
                binary.write_text('#!/bin/sh\ntouch "$HOME/unexpected-cli-call"\nexit 99\n')
                binary.chmod(0o755)
            env = {'HOME': tmp, 'PATH': tmp + os.pathsep + os.environ['PATH']}
            result = subprocess.run(
                [sys.executable, str(ROOT / 'scripts/check-marketplace.py'), '--aws-account', LAB],
                cwd=tmp, env=env, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn('No ROSA billing account selected', result.stderr)
            self.assertNotIn(LAB, result.stderr)
            self.assertFalse((directory / 'unexpected-cli-call').exists())

    def test_explicit_lab_account_remains_a_valid_selection(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'BILLING_ACCOUNT_ID': LAB}, clear=True):
            self.assertEqual(marketplace.configured_billing_account(Path(tmp)), LAB)

    def test_make_passes_the_payer_loaded_from_credentials_to_plan_and_apply(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            binary = directory / 'terraform'
            binary.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$HOME/terraform-commands"\n')
            binary.chmod(0o755)
            dotenv = directory / '.env'
            dotenv.write_text('export BILLING_ACCOUNT_ID=' + PAYER + '\n')
            env = {**os.environ, 'HOME': tmp, 'PATH': tmp + os.pathsep + os.environ['PATH'],
                   'DOTENV': str(dotenv), 'RHCS_TOKEN': 'test-only-token',
                   'AWS_ACCESS_KEY_ID': 'test', 'BILLING_ACCOUNT_ID': LAB}
            result = subprocess.run(['make', '_tf-deploy', 'NAME=test'], cwd=ROOT,
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            commands = (directory / 'terraform-commands').read_text().splitlines()
            self.assertEqual(len(commands), 2)
            for command in commands:
                self.assertIn('-var=aws_billing_account_id=' + PAYER, command)
                self.assertNotIn(LAB, command)

    def test_prereq_stops_before_iam_and_terraform_on_missing_billing(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            binary = directory / 'bin'
            binary.mkdir()
            commands = {
                'aws': '#!/bin/sh\ncase "$1 $2" in "sts get-caller-identity") echo '+LAB+';; *) echo forbidden-aws-mutation >> "$HOME/forbidden"; exit 91;; esac\n',
                'rosa': '#!/bin/sh\nif [ "$1" = login ]; then exit 0; fi\necho forbidden-rosa-mutation >> "$HOME/forbidden"; exit 91\n',
                'python3': '#!/bin/sh\ncase "$*" in *--ocm-role*) echo forbidden-ocm-check >> "$HOME/forbidden"; exit 91;; *) echo billing-not-linked >&2; exit 1;; esac\n',
                'terraform': '#!/bin/sh\necho forbidden-terraform >> "$HOME/forbidden"; exit 91\n',
                'oc': '#!/bin/sh\nexit 0\n',
            }
            for name, body in commands.items():
                path = binary / name
                path.write_text(body)
                path.chmod(0o755)
            env = {**os.environ, 'HOME': tmp, 'PATH': str(binary)+':'+os.environ['PATH'],
                   'DOTENV': str(directory / 'absent.env'), 'RHCS_TOKEN': 'test-only-token',
                   'AWS_ACCESS_KEY_ID': 'test', 'AWS_DEFAULT_REGION': 'eu-west-1'}
            result = subprocess.run(['bash', str(ROOT / 'scripts/prereq.sh')], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
            self.assertIn('billing-not-linked', result.stderr)
            self.assertFalse((directory / 'forbidden').exists())

    def test_prereq_prepares_missing_role_in_auto_mode_and_checks_it_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            binary = directory / 'bin'
            binary.mkdir()
            commands = {
                'aws': '#!/bin/sh\ncase "$1 $2" in "sts get-caller-identity") echo '+LAB+';; *) echo stopped-after-ocm-verification; exit 91;; esac\n',
                'rosa': '#!/bin/sh\nif [ "$1" = login ]; then exit 0; fi\ntest -f "$HOME/billing-checked" || exit 92\nprintf "%s\\n" "$*" > "$HOME/ocm-call"\n',
                'python3': '#!/bin/sh\ncase "$*" in *--ocm-role*) if [ -f "$HOME/ocm-checked" ]; then test -f "$HOME/ocm-call"; else touch "$HOME/ocm-checked"; exit 3; fi;; *) touch "$HOME/billing-checked";; esac\n',
                'terraform': '#!/bin/sh\necho forbidden > "$HOME/terraform-call"; exit 91\n',
                'oc': '#!/bin/sh\nexit 0\n',
            }
            for name, body in commands.items():
                path = binary / name
                path.write_text(body)
                path.chmod(0o755)
            env = {**os.environ, 'HOME': tmp, 'PATH': str(binary)+':'+os.environ['PATH'],
                   'DOTENV': str(directory / 'absent.env'), 'RHCS_TOKEN': 'test-only-token',
                   'AWS_ACCESS_KEY_ID': 'test', 'AWS_DEFAULT_REGION': 'eu-west-1'}
            result = subprocess.run(['bash', str(ROOT / 'scripts/prereq.sh')], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
            self.assertEqual((directory / 'ocm-call').read_text().strip(),
                             'create ocm-role --no-console --mode auto --prefix CloudTerminal --yes')
            self.assertIn('stopped-after-ocm-verification', result.stderr)
            self.assertFalse((directory / 'terraform-call').exists())


if __name__ == '__main__':
    unittest.main()
