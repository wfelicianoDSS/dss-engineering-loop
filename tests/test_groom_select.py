import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
import importlib.util

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "super-board-groom-select.py"
spec = importlib.util.spec_from_file_location("groom_select", SCRIPT)
groom_select = importlib.util.module_from_spec(spec)
spec.loader.exec_module(groom_select)


def cert(title, body, labels):
    return f"<!-- sb-ready v1 hash={groom_select.content_hash(title, body, labels)} checks=ac,deps,scope,risk -->"


class GroomSelectTests(unittest.TestCase):
    def run_select(self, items, comments=None, extra=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            items_path = root / "items.json"
            items_path.write_text(json.dumps({"items": items}))
            args = [sys.executable, str(SCRIPT), "--items", str(items_path)]
            if comments is not None:
                cdir = root / "comments"
                cdir.mkdir()
                for number, text in comments.items():
                    (cdir / f"{number}.md").write_text(text)
                args += ["--comments-dir", str(cdir)]
            args += extra or []
            return subprocess.run(args, capture_output=True, text=True)

    def issue(self, number=1, status="Backlog", title="US-1", body="b", labels=("feature",)):
        return {"number": number, "status": status, "title": title, "body": body,
                "labels": list(labels)}

    def test_uncertified_story_is_selected(self):
        r = self.run_select([self.issue()])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), [1])

    def test_unchanged_certificate_skips(self):
        issue = self.issue()
        r = self.run_select([issue], {1: cert(issue["title"], issue["body"], issue["labels"])})
        self.assertEqual(json.loads(r.stdout), [])

    def test_body_edit_reselects(self):
        issue = self.issue()
        r = self.run_select([issue], {1: cert(issue["title"], "old", issue["labels"])})
        self.assertEqual(json.loads(r.stdout), [1])

    def test_containers_are_skipped(self):
        items = [self.issue(number=2, title="EPIC-010 — Notifications"),
                 self.issue(number=3, title="FEAT-044 — Delivery Providers"),
                 self.issue(number=4, status="Ready"),
                 self.issue(number=5)]
        r = self.run_select(items)
        self.assertEqual(json.loads(r.stdout), [5])

    def test_certify_prints_marker(self):
        issue = self.issue()
        r = self.run_select([issue], extra=["--certify", "1"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(),
                         cert(issue["title"], issue["body"], issue["labels"]))


if __name__ == "__main__":
    unittest.main()
