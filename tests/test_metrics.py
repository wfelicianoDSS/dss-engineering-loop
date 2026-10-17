import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "super-board-metrics.py"


class MetricsTests(unittest.TestCase):
    def run_metrics(self, rows, done=10, since=None, unknown_items=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / ".claude/super-board/configs/t.json"
            config.parent.mkdir(parents=True)
            config.write_text("{}")
            ledger = root / "ledger.jsonl"
            ledger.write_text("\n".join(json.dumps(row) for row in rows))
            items = root / "items.json"
            if unknown_items:
                items.write_text("not json")
            else:
                items.write_text(json.dumps({"items": [{"status": "Done"}] * done}))
            args = [
                sys.executable, str(SCRIPT),
                "--config", str(config),
                "--ledger", str(ledger),
                "--items", str(items),
            ]
            if since:
                args += ["--since", since]
            return subprocess.run(args, capture_output=True, text=True)

    def test_counts_and_per_100(self):
        rows = [
            {"at": "2026-10-17T10:00:00Z", "class": "no_provider"},
            {"at": "2026-10-17T11:00:00Z", "class": "stale_lock"},
            {"at": "2026-10-17T12:00:00Z", "class": "no_provider"},
        ]
        result = self.run_metrics(rows, done=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("interventions: 3", result.stdout)
        self.assertIn("done: 10", result.stdout)
        self.assertIn("interventions_per_100_done: 30.0", result.stdout)
        self.assertIn("no_provider: 2", result.stdout)

    def test_since_filters(self):
        rows = [
            {"at": "2026-10-16T10:00:00Z", "class": "no_provider"},
            {"at": "2026-10-17T10:00:00Z", "class": "stale_lock"},
        ]
        result = self.run_metrics(rows, done=4, since="2026-10-17T00:00:00Z")
        self.assertIn("interventions: 1", result.stdout)
        self.assertIn("interventions_per_100_done: 25.0", result.stdout)

    def test_unknown_class_warns(self):
        result = self.run_metrics(
            [{"at": "2026-10-17T10:00:00Z", "class": "bogus"}], done=1
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning: unknown intervention classes: bogus", result.stderr)

    def test_bad_items_reports_unknown_done(self):
        result = self.run_metrics([], unknown_items=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("done: unknown", result.stdout)
        self.assertIn("interventions_per_100_done: n/a", result.stdout)


if __name__ == "__main__":
    unittest.main()
