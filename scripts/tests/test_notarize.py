"""Offline regression checks for publication gating and ambiguous upload recovery."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('notarize', Path(__file__).parents[1] / 'notarize.py')
notarize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notarize)

class NotarizeTests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ.get('TEST_ARTIFACTS_DIR', '.test-artifacts'))
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=root)
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name).resolve() / 'Example.app'
        for relative in ['Contents/MacOS/CodexAccounts', 'Contents/Info.plist', 'Contents/_CodeSignature/CodeResources']:
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'public-test-fixture')
        self.out = self.app.parent / 'notary-output'
        self.calls = []
        self.status = 'In Progress'
        self.signature = '\nAuthority=Developer ID Application: Example Developer\nTimestamp=fixture\nflags=0x10000(runtime)\n'
        self.fail_upload = False
        self.fail_assessment = False
    def fake_run(self, args, **kwargs):
        self.calls.append(args)
        stdout = ''; stderr = ''
        if args[:2] == ['codesign', '-d']:
            stderr = self.signature
        elif args[0] == 'ditto':
            Path(args[-1]).write_bytes(b'archive-fixture')
        elif args[:3] == ['xcrun', 'notarytool', 'submit']:
            if self.fail_upload: raise subprocess.CalledProcessError(1, args)
            stdout = json.dumps({'id': 'fixture-submission'})
        elif args[:3] == ['xcrun', 'notarytool', 'info']:
            stdout = json.dumps({'id': 'fixture-submission', 'status': self.status})
        elif args[0] == 'spctl' and self.fail_assessment:
            raise subprocess.CalledProcessError(3, args)
        return subprocess.CompletedProcess(args, 0, stdout, stderr)
    def phase(self, phase):
        argv = ['notarize.py', phase, '--app', str(self.app), '--output', str(self.out), '--profile', 'fixture-only']
        with patch.object(sys, 'argv', argv), patch.object(notarize, 'run', self.fake_run):
            notarize.main()
    def test_adhoc_never_prepares_or_submits(self):
        self.signature = 'Signature=adhoc\nflags=0x10000(runtime)\n'
        with self.assertRaisesRegex(RuntimeError, 'Developer ID'):
            self.phase('prepare')
        self.assertFalse(self.out.exists())
        self.assertFalse(any('notarytool' in c for c in self.calls))
    def test_ambiguous_upload_is_not_replayed(self):
        self.phase('prepare'); self.fail_upload = True
        with self.assertRaises(subprocess.CalledProcessError): self.phase('submit')
        self.fail_upload = False
        with self.assertRaisesRegex(RuntimeError, 'already attempted'): self.phase('submit')
        self.assertEqual(sum(c[:3] == ['xcrun', 'notarytool', 'submit'] for c in self.calls), 1)
    def test_pending_or_rejected_never_creates_distribution(self):
        self.phase('prepare'); self.phase('submit')
        with self.assertRaises(SystemExit) as pending: self.phase('finish')
        self.assertEqual(pending.exception.code, 2)
        self.status = 'Invalid'
        with self.assertRaisesRegex(RuntimeError, 'Not accepted'): self.phase('finish')
        self.assertFalse(any('stapler' in c for c in self.calls))
        self.assertFalse((self.out / 'Codex-Accounts-notarized.zip').exists())
    def test_accepted_still_requires_gatekeeper_before_distribution(self):
        self.phase('prepare'); self.phase('submit'); self.status = 'Accepted'
        self.fail_assessment = True
        with self.assertRaises(subprocess.CalledProcessError): self.phase('finish')
        self.assertFalse((self.out / 'Codex-Accounts-notarized.zip').exists())
        self.fail_assessment = False; self.phase('finish')
        self.assertTrue((self.out / 'SHA256SUMS.txt').exists())
        self.assertEqual(json.loads((self.out / 'state.json').read_text())['phase'], 'ready')

if __name__ == '__main__': unittest.main()
