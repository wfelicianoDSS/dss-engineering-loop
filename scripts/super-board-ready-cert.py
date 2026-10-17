#!/usr/bin/env python3
"""super-board-ready-cert.py — readiness certificate for a groomed Backlog story.

A story that passes groom/lint gets a hidden comment:

    <!-- sb-ready v1 hash=<sha256(title+body+sorted labels)[:12]> checks=ac,deps,scope,risk -->

`super-board-groom-select.py` skips a Backlog story whose current content hash is
already certified, so an unchanged, ready story is never groomed again.

    super-board-ready-cert.py --items <board-items.json> --issue <n> [--post]
                              [--comments-dir <dir>] [--checks ac,deps,scope,risk]

Without --post it prints the certificate body. With --post it posts the hidden
comment with `gh issue comment` and also records it in <comments-dir>/<n>.md so the
runner can select offline next tick.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys

DEFAULT_DIR = '.claude/super-board/ready-certs'


def _names(labels) -> list:
    return sorted(
        (label if isinstance(label, str) else (label or {}).get('name', ''))
        for label in (labels or [])
    )


def content_hash(title: str, body: str, labels) -> str:
    return hashlib.sha256(f"{title}\n{body}\n{','.join(_names(labels))}".encode('utf-8')).hexdigest()[:12]


def snapshot_hash(title: str, labels) -> str:
    # Title + labels only: the fields the runner's board snapshot carries. The
    # certificate records both so a snapshot-only reader can still match.
    return hashlib.sha256(f"{title}\n{','.join(_names(labels))}".encode('utf-8')).hexdigest()[:12]


def certificate(item, checks: str) -> str:
    title, body, labels = fields(item)
    digest = content_hash(title, body, labels)
    snap = snapshot_hash(title, labels)
    return f'<!-- sb-ready v1 hash={digest} snap={snap} checks={checks} -->'


def find_item(items, number: int):
    for item in items:
        if not isinstance(item, dict):
            continue
        content = item.get('content') or {}
        if item.get('number', content.get('number')) == number:
            return item
    return None


def fields(item) -> tuple:
    # Accept both the runner's nested board snapshot and a flat issue object.
    content = item.get('content') or {}
    return (item.get('title', content.get('title')) or '',
            item.get('body', content.get('body')) or '',
            item.get('labels', content.get('labels')))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--items', required=True)
    parser.add_argument('--issue', type=int, required=True)
    parser.add_argument('--post', action='store_true')
    parser.add_argument('--comments-dir', default=DEFAULT_DIR)
    parser.add_argument('--checks', default='ac,deps,scope,risk')
    args = parser.parse_args()

    try:
        data = json.loads(pathlib.Path(args.items).read_text())
    except (OSError, ValueError) as error:
        print(f'unreadable items: {error}', file=sys.stderr)
        return 64
    items = data.get('items', []) if isinstance(data, dict) else data
    item = find_item(items, args.issue)
    if item is None:
        print(f'issue #{args.issue} not found in items', file=sys.stderr)
        return 66

    body = certificate(item, args.checks)
    if not args.post:
        print(body)
        return 0

    result = subprocess.run(['gh', 'issue', 'comment', str(args.issue), '--body', body],
                            text=True, capture_output=True)
    if result.returncode != 0:
        print(result.stderr.strip() or 'gh issue comment failed', file=sys.stderr)
        return 1
    folder = pathlib.Path(args.comments_dir)
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f'{args.issue}.md'
    with path.open('a', encoding='utf-8') as stream:
        stream.write(body + '\n')
    print(body)
    return 0


if __name__ == '__main__':
    sys.exit(main())
