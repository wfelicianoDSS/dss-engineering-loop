#!/usr/bin/env python3
"""Reconcile contract: dispatch safety, dead-lease recovery, merged sweep, halt scope."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/super-board-reconcile.py'


class ReconcileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.leases = self.root / 'inflight'; self.leases.mkdir()
        self.providers = self.root / 'providers'; self.providers.mkdir()
        self.config = self.root / 'config.json'
        self.config.write_text(json.dumps({'notifications': {'bot_identity': 'bot'}}))
        self.items = self.root / 'items.json'
        self.halt = self.root / 'halt.json'
        self.prs = self.root / 'prs.json'
        self.journal = self.root / 'applied.json'
        self.env = dict(os.environ)

    def tearDown(self):
        self.temp.cleanup()

    def write(self):
        self.items.write_text(json.dumps({'items': [
            {'number': 1, 'status': 'Review'},
            {'number': 2, 'status': 'Ready'},
            {'number': 3, 'status': 'Ready'},
            {'number': 4, 'status': 'Ready', 'assignee': 'alice'},
            {'number': 5, 'status': 'Blocked'},
            {'number': 6, 'status': 'Review'},
        ]}))
        self.prs.write_text(json.dumps({'1': {'mergedAt': '2026-10-17T12:00:00Z',
                                              'mergeCommit': 'abc123'}}))
        # #3 has a live lease, #6 a dead one.
        (self.leases / '3').write_text(f'PID={os.getpid()}\nLANE=build\nHEARTBEAT={int(__import__("time").time())}\n')
        (self.leases / '6').write_text('PID=999999\nLANE=review\nHEARTBEAT=1\n')

    def run_plan(self, *extra):
        return subprocess.run([sys.executable, str(HELPER), '--config', str(self.config),
                               '--items', str(self.items), '--leases-dir', str(self.leases),
                               '--halt', str(self.halt), '--providers-dir', str(self.providers),
                               '--pr-state', str(self.prs), '--journal', str(self.journal), *extra],
                              env=self.env, text=True, capture_output=True)

    def test_plan_dispatch_recover_sweep(self):
        self.write()
        result = json.loads(self.run_plan().stdout)
        self.assertEqual([d['issue'] for d in result['dispatch']], [2])
        self.assertEqual([r['issue'] for r in result['recover']], [6])
        self.assertEqual([s['issue'] for s in result['sweep']], [1])

    def test_apply_is_idempotent(self):
        self.write()
        first = json.loads(self.run_plan('--apply').stdout)
        self.assertEqual([r['issue'] for r in first['applied']], [6])
        self.assertFalse((self.leases / '6').exists())
        second = json.loads(self.run_plan('--apply').stdout)
        self.assertEqual(second['applied'], [])
        self.assertEqual(second['recover'], [])

    def test_permanent_halt_reports_only(self):
        self.write()
        self.halt.write_text(json.dumps({'class': 'permanent_read'}))
        result = json.loads(self.run_plan('--apply').stdout)
        self.assertEqual(result['dispatch'], [])
        self.assertEqual(result['recover'], [])
        self.assertEqual(result['sweep'], [])
        self.assertIn('halt', result['noop_reason'])
        self.assertTrue((self.leases / '6').exists(), 'no mutation under a halt')

    def test_paused_provider_falls_through(self):
        self.write()
        (self.providers / 'claude.json').write_text(json.dumps(
            {'state': 'paused', 'paused_until': 9_999_999_999}))
        result = json.loads(self.run_plan().stdout)
        self.assertEqual(result['dispatch'][0]['provider'], 'codex')


if __name__ == '__main__':
    unittest.main()
