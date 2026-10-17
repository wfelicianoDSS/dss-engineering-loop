#!/usr/bin/env python3
"""super-board-providers.py — health-aware provider state.

One JSON file per provider in `.claude/super-board/providers/<name>.json` (override
with SB_PROVIDER_STATE_DIR). The runner asks `allowed` before dispatching a lane; a
vendor limit calls `fail --quota`, repeated non-quota failures open the circuit.

    { "state": "ok|paused|probing|open",
      "paused_until": <epoch>, "reason": "...", "consecutive_failures": 0,
      "last_success": <epoch>, "probe_interval": 900, "probe_dispatched_at": 0 }

Transitions:
  ok       → paused (quota, with/without a reset time)
  paused   → probing when paused_until has passed (one probe dispatch)
  probing  → ok on success; paused/open on failure
  any      → open after 3 consecutive non-quota failures (30 min, one attention line)
  usage unknown → not exhausted: `allowed` never treats an unknown snapshot as a limit.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import time

DEFAULT_INTERVAL = 900          # 15 min between probe dispatches
QUOTA_PAUSE = 300               # 5 min when the vendor gave no reset time
OPEN_PAUSE = 1800               # 30 min circuit-open
OPEN_AFTER = 3                  # non-quota failures before the circuit opens


def now() -> int:
    try:
        return int(os.environ.get('SB_NOW') or time.time())
    except ValueError:
        return int(time.time())


def state_dir() -> Path:
    return Path(os.environ.get('SB_PROVIDER_STATE_DIR', '.claude/super-board/providers'))


def path_for(name: str) -> Path:
    return state_dir() / f'{name}.json'


def default(name: str) -> dict:
    return {'provider': name, 'state': 'ok', 'paused_until': 0, 'reason': '',
            'consecutive_failures': 0, 'last_success': 0,
            'probe_interval': DEFAULT_INTERVAL, 'probe_dispatched_at': 0}


def load(name: str) -> dict:
    path = path_for(name)
    state = default(name)
    try:
        state.update(json.loads(path.read_text()))
    except (OSError, ValueError):
        pass
    return state


def save(state: dict) -> None:
    folder = state_dir()
    folder.mkdir(parents=True, exist_ok=True)
    path = path_for(state['provider'])
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')
    temp.replace(path)


def attention(message: str) -> None:
    folder = state_dir().parent
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / 'needs-attention.log'
    try:
        if path.exists() and now() - int(path.stat().st_mtime) < 1800:
            return
        with path.open('a', encoding='utf-8') as stream:
            stream.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now()))} {message}\n")
    except OSError:
        pass


def allowed(state: dict, stamp: int) -> tuple[bool, str]:
    """May this provider take one dispatch now? Also records the one probe."""
    kind = state.get('state', 'ok')
    if kind == 'ok':
        return True, 'ok'
    until = int(state.get('paused_until') or 0)
    if kind in ('paused', 'open') and stamp < until:
        return False, f"{kind} until {until}"
    if kind in ('paused', 'open'):
        state['state'] = 'probing'
        state['probe_dispatched_at'] = 0
        kind = 'probing'
    if kind == 'probing':
        dispatched = int(state.get('probe_dispatched_at') or 0)
        interval = int(state.get('probe_interval') or DEFAULT_INTERVAL)
        if dispatched and stamp - dispatched < interval:
            save(state)
            return False, f"probing (next probe in {interval - (stamp - dispatched)}s)"
        state['probe_dispatched_at'] = stamp
        save(state)
        return True, 'probing'
    return False, kind


def cmd_allowed(args) -> int:
    state = load(args.name)
    ok, reason = allowed(state, args.now or now())
    print(json.dumps({'provider': args.name, 'allowed': ok, 'state': state['state'],
                      'reason': reason}))
    return 0 if ok else 1


def cmd_success(args) -> int:
    state = load(args.name)
    stamp = args.now or now()
    state.update({'state': 'ok', 'paused_until': 0, 'reason': '',
                  'consecutive_failures': 0, 'last_success': stamp,
                  'probe_dispatched_at': 0})
    save(state)
    print(json.dumps(state))
    return 0


def cmd_fail(args) -> int:
    state = load(args.name)
    stamp = args.now or now()
    state['consecutive_failures'] = int(state.get('consecutive_failures') or 0) + 1
    if args.quota:
        until = args.until or (stamp + QUOTA_PAUSE)
        state.update({'state': 'paused', 'paused_until': until,
                      'reason': args.reason or 'vendor quota', 'probe_dispatched_at': 0})
    elif state['consecutive_failures'] >= OPEN_AFTER:
        state.update({'state': 'open', 'paused_until': stamp + OPEN_PAUSE,
                      'reason': args.reason or 'repeated non-quota failures',
                      'probe_dispatched_at': 0})
        attention(f"provider {args.name} circuit open for {OPEN_PAUSE}s after "
                  f"{state['consecutive_failures']} failures: {state['reason']}")
    save(state)
    print(json.dumps(state))
    return 0


def cmd_pause(args) -> int:
    state = load(args.name)
    stamp = args.now or now()
    state.update({'state': 'paused',
                  'paused_until': args.until or (stamp + QUOTA_PAUSE),
                  'reason': args.reason or 'paused', 'probe_dispatched_at': 0})
    save(state)
    print(json.dumps(state))
    return 0


def cmd_wake_at(args) -> int:
    stamps = []
    folder = state_dir()
    if folder.is_dir():
        for path in folder.glob('*.json'):
            try:
                state = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if state.get('state') in ('paused', 'open', 'probing'):
                until = int(state.get('paused_until') or 0)
                if state.get('state') == 'probing':
                    until = int(state.get('probe_dispatched_at') or 0) + int(state.get('probe_interval') or DEFAULT_INTERVAL)
                if until:
                    stamps.append(until)
    print(min(stamps) if stamps else 0)
    return 0


def cmd_get(args) -> int:
    print(json.dumps(load(args.name)))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--now', type=int, default=0, help='injected clock for tests')
    sub = parser.add_subparsers(dest='command', required=True)

    p = sub.add_parser('allowed'); p.add_argument('name'); p.set_defaults(func=cmd_allowed)
    p = sub.add_parser('success'); p.add_argument('name'); p.set_defaults(func=cmd_success)
    p = sub.add_parser('fail'); p.add_argument('name'); p.add_argument('--quota', action='store_true')
    p.add_argument('--until', type=int, default=0); p.add_argument('--reason', default='')
    p.set_defaults(func=cmd_fail)
    p = sub.add_parser('pause'); p.add_argument('name'); p.add_argument('--until', type=int, default=0)
    p.add_argument('--reason', default=''); p.set_defaults(func=cmd_pause)
    p = sub.add_parser('wake-at'); p.set_defaults(func=cmd_wake_at)
    p = sub.add_parser('get'); p.add_argument('name'); p.set_defaults(func=cmd_get)
    args = parser.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
