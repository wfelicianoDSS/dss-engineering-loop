#!/usr/bin/env python3
"""Provider health state: quota pause, one probe, circuit open/close, wake time."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/super-board-providers.py'


class ProviderStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.dir = self.root / 'providers'
        self.env = dict(os.environ, SB_PROVIDER_STATE_DIR=str(self.dir))

    def tearDown(self):
        self.temp.cleanup()

    def run_cmd(self, *args, now=1_000_000):
        return subprocess.run([sys.executable, str(HELPER), '--now', str(now), *args],
                              env=self.env, text=True, capture_output=True)

    def state(self, name='claude'):
        return json.loads((self.dir / f'{name}.json').read_text())

    def allowed(self, name='claude', now=1_000_000):
        result = self.run_cmd('allowed', name, now=now)
        return result.returncode == 0, json.loads(result.stdout)

    def test_no_state_file_means_ok(self):
        ok, detail = self.allowed()
        self.assertTrue(ok)
        self.assertEqual(detail['state'], 'ok')

    def test_quota_pause_expires_into_one_probe(self):
        self.run_cmd('fail', 'claude', '--quota')
        self.assertFalse(self.allowed(now=1_000_100)[0], 'inside the quota pause')
        ok, detail = self.allowed(now=1_001_000)
        self.assertTrue(ok, detail)
        self.assertEqual(detail['state'], 'probing')
        self.assertFalse(self.allowed(now=1_001_010)[0], 'one probe per interval')
        self.assertTrue(self.allowed(now=1_001_910)[0], 'next probe after the interval')

    def test_success_closes_probe(self):
        self.run_cmd('fail', 'claude', '--quota')
        self.assertTrue(self.allowed(now=1_001_000)[0])
        self.run_cmd('success', 'claude', now=1_001_010)
        self.assertEqual(self.state()['state'], 'ok')
        self.assertTrue(self.allowed(now=1_001_020)[0])

    def test_three_non_quota_failures_open_the_circuit(self):
        for _ in range(3):
            self.run_cmd('fail', 'codex', '--reason', 'crash')
        state = self.state('codex')
        self.assertEqual(state['state'], 'open')
        self.assertFalse(self.allowed('codex', now=1_000_100)[0])
        attention = (self.root / 'needs-attention.log').read_text()
        self.assertEqual(len(attention.splitlines()), 1, 'one attention line, not one per failure')
        self.assertTrue(self.allowed('codex', now=1_031_000)[0], 'reopens into a probe')

    def test_wake_at_is_the_earliest_wake(self):
        self.run_cmd('pause', 'claude', '--until', '1000040')
        self.run_cmd('pause', 'codex', '--until', '1000200')
        result = self.run_cmd('wake-at')
        self.assertEqual(result.stdout.strip(), '1000040')


if __name__ == '__main__':
    unittest.main()
