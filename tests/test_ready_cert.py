#!/usr/bin/env python3
"""Readiness certificates: the comment body, the offline cache, and selection.

A certified, unchanged story is not selected for grooming again; an edit changes the
hash and re-selects it.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CERT = ROOT / 'scripts/super-board-ready-cert.py'
SELECT = ROOT / 'scripts/super-board-groom-select.py'


class ReadyCertTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.items = self.root / 'items.json'
        self.comments = self.root / 'comments'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        gh = self.bin / 'gh'
        gh.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$GH_LOG"\nexit 0\n')
        gh.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        GH_LOG=str(self.root / 'gh.log'))
        self.issue = {'number': 7, 'status': 'Backlog', 'title': 'US-7',
                      'body': 'story', 'labels': ['feature']}
        self.write_items([self.issue])

    def tearDown(self):
        self.temp.cleanup()

    def write_items(self, items):
        self.items.write_text(json.dumps({'items': items}))

    def cert(self, *args):
        return subprocess.run([sys.executable, str(CERT), '--items', str(self.items),
                               '--issue', '7', '--comments-dir', str(self.comments), *args],
                              env=self.env, text=True, capture_output=True)

    def select(self):
        result = subprocess.run([sys.executable, str(SELECT), '--items', str(self.items),
                                 '--comments-dir', str(self.comments)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_uncertified_is_selected(self):
        self.assertEqual(self.select(), [7])

    def test_nested_board_shape_works(self):
        nested = {'status': 'Backlog', 'content': {
            'number': 7, 'title': 'US-7', 'body': 'story', 'labels': ['feature']}}
        self.write_items([nested])
        result = self.cert('--post')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.select(), [])

    def test_post_writes_comment_and_offline_cache(self):
        result = self.cert('--post')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('<!-- sb-ready v1 hash='))
        self.assertIn('issue comment 7 --body', (self.root / 'gh.log').read_text())
        cached = (self.comments / '7.md').read_text()
        self.assertEqual(cached.strip(), result.stdout.strip())
        self.assertEqual(self.select(), [], 'a certified unchanged story is skipped')

    def test_edit_invalidates_the_certificate(self):
        self.assertEqual(self.cert('--post').returncode, 0)
        edited = dict(self.issue, body='story changed')
        self.write_items([edited])
        self.assertEqual(self.select(), [7], 'a body edit re-selects the story')

    def test_missing_issue_is_a_caller_error(self):
        result = subprocess.run([sys.executable, str(CERT), '--items', str(self.items),
                                 '--issue', '99', '--comments-dir', str(self.comments)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 66)


if __name__ == '__main__':
    unittest.main()
