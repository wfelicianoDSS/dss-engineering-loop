#!/usr/bin/env python3
"""super-board-groom-select.py — pick only Backlog issues without a valid readiness certificate.

    super-board-groom-select.py --items <board-items.json> [--comments-dir <dir>]

A readiness certificate is a hidden comment left after a story passes groom/lint:

    <!-- sb-ready v1 hash=<sha256(title+body+labels)[:12]> checks=ac,deps,scope,risk -->

An issue is selected when it has no certificate, or the certificate hash differs from the
issue's current content hash (title + body + sorted labels). Prints a JSON list of numbers.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys

MARK = re.compile(r"<!--\s*sb-ready v1 hash=([0-9a-f]{12})(?: snap=([0-9a-f]{12}))?")


def _hash(payload: str) -> str:
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:12]


def content_hash(title: str, body: str, labels) -> str:
    names = sorted(
        (l if isinstance(l, str) else (l or {}).get("name", "")) for l in (labels or [])
    )
    return _hash(f"{title}\n{body}\n{','.join(names)}")


def snapshot_hash(title: str, labels) -> str:
    """Title + labels only — the fields the runner's board snapshot actually carries.

    The full hash stays the source of truth when the caller has the body. The board
    snapshot does not, so the certificate also carries this narrower hash; otherwise
    every selection would look stale and re-groom the whole backlog forever.
    """
    names = sorted(
        (l if isinstance(l, str) else (l or {}).get("name", "")) for l in (labels or [])
    )
    return _hash(f"{title}\n{','.join(names)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--items", required=True)
    parser.add_argument("--comments-dir", default=None,
                        help="directory of <issue>.md files holding the issue comments")
    args = parser.parse_args()

    try:
        data = json.loads(pathlib.Path(args.items).read_text())
    except (OSError, ValueError) as error:
        print(f"unreadable items: {error}", file=sys.stderr)
        return 64

    items = data.get("items", []) if isinstance(data, dict) else data
    selected = []
    for item in items:
        if not isinstance(item, dict) or item.get("status") != "Backlog":
            continue
        # The runner's board snapshot nests the issue under `content`; the groom
        # worker's flat item list does not. Accept both shapes.
        content = item.get("content") or {}
        number = item.get("number", content.get("number"))
        if type(number) is not int:
            continue
        title = item.get("title", content.get("title")) or ""
        labels = item.get("labels", content.get("labels"))
        body = item.get("body", content.get("body"))
        if "content" in item and "body" not in content:
            wanted = snapshot_hash(title, labels)
        else:
            wanted = content_hash(title, body or "", labels)
        text = ""
        if args.comments_dir:
            path = pathlib.Path(args.comments_dir) / f"{number}.md"
            if path.exists():
                text = path.read_text()
        certified = {value for pair in MARK.findall(text) for value in pair if value}
        if not certified or wanted not in certified:
            selected.append(number)

    print(json.dumps(selected))
    return 0


if __name__ == "__main__":
    sys.exit(main())
