import importlib.util
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

reporting = load('verification_report', 'verify-report.py')
audit = load('hap_audit', 'audit-hap.py')


class VerificationTests(unittest.TestCase):
    def test_failed_command_keeps_later_checks_not_run_and_redacts_private_pem(self):
        with tempfile.TemporaryDirectory() as directory:
            steps = [('failing', []), ('later', [])]
            reporter = reporting.Reporter(directory, 'unit', steps)
            code = "print('-----BEGIN OPENSSH PRIVATE KEY-----'); print('synthetic-sensitive-material'); print('-----END OPENSSH PRIVATE KEY-----'); raise SystemExit(7)"
            self.assertFalse(reporter.run(0, [sys.executable, '-c', code]))
            self.assertFalse(reporter.finish(False))
            result = json.loads((Path(directory) / 'report.json').read_text())
            self.assertEqual(result['steps'][0]['exitCode'], 7)
            self.assertEqual(result['steps'][1]['status'], 'not_run')
            self.assertNotIn('synthetic-sensitive-material', (Path(directory) / 'failing.log').read_text())

    def test_hap_audit_rejects_probe_and_development_files(self):
        for forbidden, body in [('ets/modules.abc', b'HT_PROBE_disposable'), ('tests/fixture.txt', b'fixture')]:
            with self.subTest(forbidden=forbidden), tempfile.TemporaryDirectory() as directory:
                artifact = Path(directory) / 'fixture.hap'
                with zipfile.ZipFile(artifact, 'w') as package:
                    for abi in ['arm64-v8a', 'x86_64']:
                        for name in ['libentry.so', 'libssh.so.4', 'libcrypto.so.3']:
                            package.writestr(f'libs/{abi}/{name}', b'not an executable')
                    package.writestr(forbidden, body)
                with self.assertRaises(AssertionError):
                    audit.audit(artifact)

    def test_source_change_cannot_be_reported_as_a_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            reporter = reporting.Reporter(directory, 'unit', [])
            reporter.report['sourceSha256'] = 'different-source'
            self.assertFalse(reporter.finish(True))
            self.assertTrue(reporter.report['sourceChanged'])


if __name__ == '__main__':
    unittest.main()
