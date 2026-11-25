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
spec = importlib.util.spec_from_file_location('ocm_role', ROOT / 'scripts/check-ocm-role.py')
ocm_role = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ocm_role)
LAB, ORG = '111111111111', 'workshop-org'


class OCMRoleTests(unittest.TestCase):
    def request(self, request, timeout):
        self.assertEqual(request.get_method(), 'GET')
        self.assertEqual(request.get_header('Authorization'), 'Bearer test-token')
        if request.full_url.endswith('/current_account'):
            return io.BytesIO(json.dumps({'organization': {'id': ORG}}).encode())
        if request.full_url.endswith('/labels/sts_ocm_role'):
            return io.BytesIO(json.dumps({'value': 'arn:aws:iam::'+LAB+':role/Existing'}).encode())
        self.fail('Unexpected endpoint')

    def test_finds_existing_role_for_aws_account(self):
        with patch.object(ocm_role.urllib.request, 'urlopen', side_effect=self.request):
            self.assertEqual(ocm_role.check_ocm_role(LAB, 'test-token'),
                             'arn:aws:iam::' + LAB + ':role/Existing')

    def test_reports_missing_role_for_different_aws_account(self):
        with patch.object(ocm_role.urllib.request, 'urlopen', side_effect=self.request):
            with self.assertRaises(ocm_role.MissingOCMRole):
                ocm_role.check_ocm_role('222222222222', 'test-token')

    def test_api_failure_does_not_expose_response_or_token(self):
        error = urllib.error.HTTPError('https://example.test', 403, 'sensitive-upstream', {}, io.BytesIO(b'sensitive-body'))
        with patch.object(ocm_role.urllib.request, 'urlopen', side_effect=error):
            with self.assertRaises(ocm_role.PrerequisiteError) as result:
                ocm_role.check_ocm_role(LAB, 'test-token')
            self.assertIn('403', str(result.exception))
            self.assertNotIn('sensitive', str(result.exception))

    def test_outdated_cli_upgrade_rejects_a_bad_checksum_without_replacing_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            binary = directory / 'bin'
            binary.mkdir()
            commands = {
                'rosa': '#!/bin/sh\nif [ "$*" = "create ocm-role --help" ]; then echo --admin; exit 0; fi\ntouch "$HOME/forbidden"; exit 91\n',
                'curl': '#!/bin/sh\nprintf "%s\\n" "$*" > "$HOME/download-call"\nfor arg; do dest="$arg"; done\nprintf corrupt-archive > "$dest"\n',
                'terraform': '#!/bin/sh\ntouch "$HOME/forbidden"; exit 91\n',
            }
            for name, body in commands.items():
                path = binary / name
                path.write_text(body)
                path.chmod(0o755)
            original = (binary / 'rosa').read_bytes()
            env = {**os.environ, 'HOME': tmp, 'PATH': str(binary)+':'+os.environ['PATH'],
                   'DOTENV': str(directory / 'absent.env'), 'RHCS_TOKEN': 'test-only-token',
                   'AWS_ACCESS_KEY_ID': 'test'}
            result = subprocess.run(['bash', str(ROOT / 'scripts/prereq.sh')], env=env,
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('pub/cgw/rosa/1.2.66/', (directory / 'download-call').read_text())
            self.assertIn('FAILED', result.stdout)
            self.assertEqual((binary / 'rosa').read_bytes(), original)
            self.assertFalse((directory / 'forbidden').exists())

    def test_prereq_prepares_missing_role_in_auto_mode_and_checks_it_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            binary = directory / 'bin'
            binary.mkdir()
            commands = {
                'aws': '#!/bin/sh\ncase "$1 $2" in "sts get-caller-identity") echo '+LAB+';; *) echo stopped-after-ocm-verification; exit 91;; esac\n',
                'rosa': '#!/bin/sh\nif [ "$*" = "create ocm-role --help" ]; then echo --no-console; exit 0; fi\nif [ "$1" = login ]; then exit 0; fi\ntest -f "$HOME/ocm-checked" || exit 92\nprintf "%s\\n" "$*" > "$HOME/ocm-call"\n',
                'python3': '#!/bin/sh\ntest "$#" = 2 && test "${1##*/}" = check-ocm-role.py && test "$2" = '+LAB+' || exit 92\nif [ -f "$HOME/ocm-checked" ]; then test -f "$HOME/ocm-call"; else touch "$HOME/ocm-checked"; exit 3; fi\n',
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
