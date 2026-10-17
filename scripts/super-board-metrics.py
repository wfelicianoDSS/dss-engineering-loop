#!/usr/bin/env python3
"""super-board-metrics.py — autonomy metrics from the intervention ledger.

    super-board-metrics.py --config <cfg> [--since <iso>] [--ledger <path>] [--items <path>]

One line per manual orchestrator action lives in
`.claude/super-board/interventions.jsonl`:

    {"at":"<iso>","class":"<class>","card":<n|null>,"action":"<what>","minutes":<n>}

`class` is a closed set (see docs/super-board/orchestrator.md): github_read_halt, no_provider,
stale_lock, rebuild_cap, groom_repeat, runner_down, branch_drift, scope_decision, human_gate,
other.

This prints the Done count, interventions total + by class, and interventions per 100 Done.
Median Blocked time and wasted dispatches arrive with later PRs, where the data exists.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

CLASSES = {
    "github_read_halt",
    "no_provider",
    "stale_lock",
    "rebuild_cap",
    "groom_repeat",
    "runner_down",
    "branch_drift",
    "scope_decision",
    "human_gate",
    "other",
}


def root_for(config: str) -> pathlib.Path:
    """Repo root from `.claude/super-board/configs/<slug>.json`."""
    path = pathlib.Path(config).resolve()
    try:
        return path.parents[3]
    except IndexError:
        return pathlib.Path.cwd()


def load_ledger(path: pathlib.Path, since):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        if since and str(row.get("at", "")) < since:
            continue
        rows.append(row)
    return rows


def done_count(items_path):
    if not items_path:
        return None
    try:
        data = json.loads(pathlib.Path(items_path).read_text())
    except (OSError, ValueError):
        return None
    items = data.get("items", []) if isinstance(data, dict) else data
    return sum(1 for i in items if isinstance(i, dict) and i.get("status") == "Done")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--since", default=None)
    parser.add_argument("--ledger", default=None)
    parser.add_argument("--items", default=None)
    args = parser.parse_args()

    root = root_for(args.config)
    ledger = pathlib.Path(args.ledger) if args.ledger else (
        root / ".claude/super-board/interventions.jsonl"
    )
    rows = load_ledger(ledger, args.since)
    done = done_count(args.items)

    by_class = {}
    for row in rows:
        name = str(row.get("class", "other"))
        by_class[name] = by_class.get(name, 0) + 1

    total = len(rows)
    if done is None:
        per_100 = "n/a"
    elif done:
        per_100 = f"{total * 100 / done:.1f}"
    else:
        per_100 = "n/a"

    print(f"interventions: {total}")
    print(f"done: {done if done is not None else 'unknown'}")
    print(f"interventions_per_100_done: {per_100}")
    for name in sorted(by_class):
        print(f"  {name}: {by_class[name]}")

    unknown = sorted(name for name in by_class if name not in CLASSES)
    if unknown:
        print(f"warning: unknown intervention classes: {', '.join(unknown)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
