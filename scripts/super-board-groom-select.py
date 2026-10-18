#!/usr/bin/env python3
"""super-board-groom-select.py — pick only Backlog stories without a valid readiness certificate.

    super-board-groom-select.py --items <board-items.json> [--comments-dir <dir>]
    super-board-groom-select.py --items <board-items.json> --certify <issue>

A readiness certificate is a hidden comment left after a story passes groom/lint:

    <!-- sb-ready v1 hash=<sha256(title+body+labels)[:12]> checks=ac,deps,scope,risk -->

Selection: only Backlog **stories** (epic/feature containers are skipped) whose certificate is
missing or whose hash differs from the current title+body+sorted labels. `--certify` prints the
exact certificate line so the groom can post it after moving the story to Ready.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys

MARK = re.compile(r"<!--\s*sb-ready v1 hash=([0-9a-f]{12})")
CONTAINER = re.compile(r"^(?:EPIC|FEAT)-\d+", re.IGNORECASE)


def label_names(labels) -> list[str]:
    return sorted((l if isinstance(l, str) else (l or {}).get("name", "")) for l in (labels or []))


def content_hash(title: str, body: str, labels) -> str:
    payload = f"{title}\n{body}\n{','.join(label_names(labels))}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:12]


def certificate(number: int, item: dict) -> str:
    digest = content_hash(item.get("title") or "", item.get("body") or "", item.get("labels"))
    return f"<!-- sb-ready v1 hash={digest} checks=ac,deps,scope,risk -->"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--items", required=True)
    parser.add_argument("--comments-dir", default=None,
                        help="directory of <issue>.md files holding the issue comments")
    parser.add_argument("--certify", type=int, default=None,
                        help="print the certificate line for this issue")
    args = parser.parse_args()

    try:
        data = json.loads(pathlib.Path(args.items).read_text())
    except (OSError, ValueError) as error:
        print(f"unreadable items: {error}", file=sys.stderr)
        return 64

    raw_items = data.get("items", []) if isinstance(data, dict) else data
    # Board items carry number/title under `content`; normalize both shapes.
    items = []
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        content = raw.get("content") if isinstance(raw.get("content"), dict) else {}
        number = raw.get("number", content.get("number"))
        if type(number) is not int:
            continue
        items.append({
            "number": number,
            "title": raw.get("title") or content.get("title") or "",
            "body": raw.get("body") or "",
            "labels": raw.get("labels") or [],
            "status": raw.get("status"),
        })

    if args.certify is not None:
        match = next((i for i in items if i["number"] == args.certify), None)
        if match is None:
            print(f"issue {args.certify} not in items", file=sys.stderr)
            return 66
        print(certificate(args.certify, match))
        return 0

    selected = []
    for item in items:
        if item.get("status") != "Backlog":
            continue
        # Epic/feature containers are roadmap scaffolding, never executable stories.
        if CONTAINER.match(item.get("title") or ""):
            continue
        number = item["number"]
        wanted = content_hash(item.get("title") or "", item.get("body") or "",
                              item.get("labels"))
        text = ""
        if args.comments_dir:
            path = pathlib.Path(args.comments_dir) / f"{number}.md"
            if path.exists():
                text = path.read_text()
        certified = MARK.findall(text)
        if not certified or wanted not in certified:
            selected.append(number)

    print(json.dumps(selected))
    return 0


if __name__ == "__main__":
    sys.exit(main())
