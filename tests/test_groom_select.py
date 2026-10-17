import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "super-board-groom-select.py"
sys.path.insert(0, str(SCRIPT.parent))
import importlib.util

spec = importlib.util.spec_from_file_location("groom_select", SCRIPT)
groom_select = importlib.util.module_from_spec(spec)
spec.loader.exec_module(groom_select)


def cert(number, title, body, labels):
    h = groom_select.content_hash(title, body, labels)
    return f"<!-- sb-ready v1 hash={h} checks=ac,deps,scope,risk -->"


class GroomSelectTests(unittest.TestCase):
    def run_select(self, items, comments=None):
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
            result = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def issue(self, number=1, status="Backlog", title="US-1", body="b", labels=("feature",)):
        return {"number": number, "status": status, "title": title, "body": body,
                "labels": list(labels)}

    def test_uncertified_is_selected(self):
        self.assertEqual(self.run_select([self.issue()]), [1])

    def test_unchanged_certificate_is_skipped(self):
        issue = self.issue()
        comments = {1: cert(1, issue["title"], issue["body"], issue["labels"])}
        self.assertEqual(self.run_select([issue], comments), [])

    def test_body_edit_is_selected(self):
        issue = self.issue()
        stale = cert(1, issue["title"], "old body", issue["labels"])
        self.assertEqual(self.run_select([issue], {1: stale}), [1])

    def test_non_backlog_and_non_issue_skipped(self):
        items = [self.issue(status="Ready"), self.issue(number=2, status="Backlog"), "junk"]
        self.assertEqual(self.run_select(items), [2])


if __name__ == "__main__":
    unittest.main()
