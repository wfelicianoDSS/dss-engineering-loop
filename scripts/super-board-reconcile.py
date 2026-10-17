#!/usr/bin/env python3
"""super-board-reconcile.py — one recovery contract per tick.

Reads the board snapshot, leases, the halt record and provider state, and prints the
safe actions for this tick:

    {"dispatch":[{issue,lane,provider}], "recover":[{issue,action,reason}],
     "sweep":[{issue,action,merge_commit}], "resume":[...], "escalate":[...],
     "noop_reason": ""}

`--apply` performs only the transport-safe subset here: release a dead/stale lease
(remove the lock + bot assignee) and record applied actions in a journal so a second
run is a no-op. Column moves and dispatch stay with the runner, which owns the board
field ids — the plan stays the single source of what should happen.

Invariants (each tested):
  * idempotent: a second --apply changes nothing;
  * never dispatch a live lease or a non-bot assignee;
  * never move a human block (Blocked is report-only);
  * with a non-transient halt, report only.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def now() -> int:
    try:
        return int(os.environ.get('SB_NOW') or time.time())
    except ValueError:
        return int(time.time())


def load_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def live(pid: int) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def read_leases(folder) -> dict:
    out = {}
    path = Path(folder)
    if not path.is_dir():
        return out
    for lease in path.glob('*'):
        if not lease.name.isdigit():
            continue
        data = {}
        try:
            for line in lease.read_text().splitlines():
                if '=' in line:
                    key, _, value = line.partition('=')
                    data[key.strip()] = value.strip()
        except OSError:
            continue
        try:
            pid = int(data.get('PID') or 0)
        except ValueError:
            pid = 0
        try:
            heartbeat = int(data.get('HEARTBEAT') or 0)
        except ValueError:
            heartbeat = 0
        out[int(lease.name)] = {'pid': pid, 'heartbeat': heartbeat,
                                'lane': data.get('LANE', ''), 'provider': data.get('PROVIDER', '')}
    return out


def provider_ok(folder, name, stamp) -> bool:
    data = load_json(Path(folder) / f'{name}.json', {})
    kind = data.get('state', 'ok')
    if kind == 'ok':
        return True
    until = int(data.get('paused_until') or 0)
    if kind in ('paused', 'open') and stamp < until:
        return False
    if kind == 'probing':
        dispatched = int(data.get('probe_dispatched_at') or 0)
        interval = int(data.get('probe_interval') or 900)
        return not dispatched or stamp - dispatched >= interval
    return True


def plan(args) -> dict:
    items = load_json(args.items, {})
    items = items.get('items', []) if isinstance(items, dict) else items
    leases = read_leases(args.leases_dir)
    stamp = args.now or now()
    cfg = load_json(args.config, {})
    bot = (cfg.get('notifications') or {}).get('bot_identity') or cfg.get('bot_identity') or ''
    ttl = int(cfg.get('lease_ttl_seconds') or 2700)
    pr_state = load_json(args.pr_state, {}) if args.pr_state else {}

    result = {'dispatch': [], 'recover': [], 'sweep': [], 'resume': [],
              'escalate': [], 'noop_reason': ''}

    halt = load_json(args.halt, {}) if args.halt else {}
    if halt:
        cls = halt.get('class') or 'permanent_read'
        if cls != 'transient_read':
            result['noop_reason'] = f'halt: {cls} — report only, no mutations'
            return result

    for issue, lease in leases.items():
        reason = ''
        if not live(lease['pid']):
            reason = 'dead lease'
        elif lease['heartbeat'] and stamp - lease['heartbeat'] > ttl:
            reason = 'stale lease heartbeat'
        if reason:
            result['recover'].append({'issue': issue, 'action': 'release', 'reason': reason})

    busy = set(leases)
    for item in items:
        if not isinstance(item, dict):
            continue
        number = item.get('number')
        status = item.get('status')
        if not isinstance(number, int) or not status:
            continue
        if status == 'Blocked':
            continue  # human/transient condition: never moved by reconcile
        if status == 'Review':
            state = pr_state.get(str(number)) or pr_state.get(number) or {}
            if state.get('mergedAt') and state.get('mergeCommit'):
                result['sweep'].append({'issue': number, 'action': 'done',
                                        'merge_commit': state['mergeCommit']})
                continue
        assignee = item.get('assignee') or item.get('assignees') or ''
        if isinstance(assignee, list):
            names = [a if isinstance(a, str) else (a or {}).get('login', '') for a in assignee]
            assignee = ','.join(n for n in names if n)
        if assignee and assignee != bot:
            continue  # a person owns it
        if number in busy:
            continue
        lane = 'review' if status == 'Review' else 'qa' if status == 'QA' else 'build' if status in ('Ready', 'Building') else ''
        if not lane:
            continue
        order = ('claude', 'codex') if lane == 'review' else ('claude', 'codex', 'deepseek', 'openrouter')
        provider = next((p for p in order if provider_ok(args.providers_dir, p, stamp)), '')
        if provider:
            result['dispatch'].append({'issue': number, 'lane': lane, 'provider': provider})
    return result


def apply_plan(args, outcome: dict) -> list:
    applied = []
    journal_path = Path(args.journal)
    journal = load_json(journal_path, {'released': []})
    released = set(journal.get('released', []))
    for action in outcome['recover']:
        issue = action['issue']
        if action.get('reason') != 'dead lease':
            continue  # a live-but-stale worker is the runner's reap/kill decision
        if issue in released:
            continue
        lease = Path(args.leases_dir) / str(issue)
        try:
            lease.unlink()
        except OSError:
            pass
        config = load_json(args.config, {})
        bot = (config.get('notifications') or {}).get('bot_identity') or config.get('bot_identity') or ''
        if bot:
            subprocess.run(['gh', 'issue', 'edit', str(issue), '--remove-assignee', bot],
                           capture_output=True)
        journal.setdefault('released', []).append(issue)
        applied.append(action)
    journal_path.parent.mkdir(parents=True, exist_ok=True)
    journal_path.write_text(json.dumps(journal, indent=2, sort_keys=True) + '\n')
    return applied


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--items', required=True)
    parser.add_argument('--leases-dir', default='.claude/super-board/inflight')
    parser.add_argument('--halt', default='.claude/super-board/github-halt.json')
    parser.add_argument('--providers-dir', default='.claude/super-board/providers')
    parser.add_argument('--pr-state', default='')
    parser.add_argument('--journal', default='.claude/super-board/reconcile-applied.json')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--now', type=int, default=0)
    args = parser.parse_args()

    outcome = plan(args)
    if args.apply:
        outcome['applied'] = apply_plan(args, outcome)
    print(json.dumps(outcome))
    return 0


if __name__ == '__main__':
    sys.exit(main())
