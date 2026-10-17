#!/usr/bin/env bash
# super-board-deepseek-lane.sh — one headless lane via the OpenCode agent
# harness (provider: deepseek), running with REAL tools (bash, edit, read, …).
#
# Same fallback-only contract as super-board-codex-lane.sh: Review is always
# refused here — fallback workers may Build/QA/Groom, never own Review or merge.
#
# Usage: --config f --lane build|qa|groom [--card '<JSON>'] [--model <model>]
#   --card is required for build/qa and omitted for groom (the Backlog → Ready lane).
# Model: --model wins; else config.deepseek.model; else a fixed default.
#        The "deepseek/" provider prefix is added automatically when missing.
# Binary: $SUPER_BOARD_OPENCODE_BIN, else the newest ~/.opencode/versions/1.*/opencode[.exe],
#         else `opencode` on PATH. Use OpenCode v1 (v2 collides with the running service).
# Auth: OpenCode's own stored DeepSeek credential (`opencode auth`); no env key needed.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys

def fail(message, code=64):
    print(message, file=sys.stderr)
    sys.exit(code)

LEG = 'deepseek'
PROVIDER = 'deepseek'
DEFAULT_MODEL = 'deepseek-flash'
SKILL = {'build': 'super-build', 'qa': 'super-qa', 'groom': 'super-groom'}
SECTION = {'build': 'Builder', 'qa': 'Tester', 'groom': 'Super Groom'}

parser = argparse.ArgumentParser(description='Run one DeepSeek board lane via the OpenCode harness (fallback only; never Review).')
parser.add_argument('--config', required=True)
parser.add_argument('--card', help='card JSON or a JSON file (required for build/qa)')
parser.add_argument('--lane', required=True, choices=['build', 'qa', 'groom'])
parser.add_argument('--model')
args = parser.parse_args(sys.argv[2:])
script_path = Path(sys.argv[1]).resolve()

try:
    config_path = Path(args.config).resolve()
    config = json.loads(config_path.read_text())
    if not isinstance(config, dict):
        raise ValueError('config must be an object')
    card = None
    if args.lane != 'groom':
        card = json.loads(args.card if args.card and args.card.lstrip().startswith('{') else Path(args.card).read_text())
        if not isinstance(card, dict):
            raise ValueError('card must be an object')
        if type(card.get('number')) is not int or card['number'] < 1 or not isinstance(card.get('status'), str):
            raise ValueError('card needs a positive issue number and status')
    if args.lane == 'groom':
        # The groom lane (Backlog → Ready) is authorized by groom.providers, not usage_fallback:
        # it must keep feeding Ready even when the paid build/qa legs are turned off, or the
        # board starves (2026-10-15).
        if LEG not in ((config.get('groom') or {}).get('providers') or []):
            fail(f'groom refused: "{LEG}" is not in groom.providers in {config_path}.', 78)
    elif config.get('usage_fallback') != LEG and LEG not in (config.get('usage_fallback') or []):
        fail(f'DeepSeek fallback refused: usage_fallback does not include "{LEG}" in {config_path}.', 78)
    configured = (config.get(LEG) or {}).get('model')
    if configured is not None and not isinstance(configured, str):
        raise ValueError(f'{LEG}.model must be a string')
    base = args.model if args.model else (configured.strip() if configured and configured.strip() else DEFAULT_MODEL)
    model = base if base.startswith(PROVIDER + '/') else f'{PROVIDER}/{base}'
except (OSError, ValueError, AttributeError) as error:
    fail(f'Invalid DeepSeek lane input: {error}')


def find_opencode():
    override = os.environ.get('SUPER_BOARD_OPENCODE_BIN')
    if override:
        return override
    versions = Path.home() / '.opencode' / 'versions'
    best = None
    if versions.is_dir():
        for d in versions.iterdir():
            if not d.name.startswith('1.'):
                continue
            for name in ('opencode.exe', 'opencode'):
                candidate = d / name
                if candidate.exists():
                    key = [int(n) for n in re.findall(r'\d+', d.name)]
                    if best is None or key > best[0]:
                        best = (key, str(candidate))
    if best:
        return best[1]
    return shutil.which('opencode') or 'opencode'


opencode = find_opencode()


def git_path(option):
    return Path(subprocess.check_output(['git', 'rev-parse', option], text=True).strip()).resolve()


try:
    root = git_path('--show-toplevel')
except subprocess.CalledProcessError:
    fail('DeepSeek lane must start inside the target git repository')
os.chdir(root)
helper = script_path.with_name('super-board-github-read.py')
column = card['status'] if card else 'Backlog'


def result(status, detail):
    print(json.dumps({'status': status, 'column': column, 'detail': detail}))


if not helper.exists() or subprocess.run([sys.executable, str(helper), '--check']).returncode:
    result('halted', 'required GitHub reads halted or helper missing; preserve claims and worktrees')
    sys.exit(79)

skill = SKILL[args.lane]
section = SECTION[args.lane]
target = f"issue #{card['number']}" if card else "the board"
prompt = f'''Run {skill} for {target} as a DeepSeek lane worker (model: {model}).
Config: {config_path}
Card: {json.dumps(card) if card else 'none (Backlog → Ready grooming lane)'}
Read .claude/skills/{skill}/SKILL.md and .claude/skills/super-board/references/run.md → {section} lifecycle; follow all its board, branch, worktree, comments, test and merge requirements.
Source .claude/bin/super-board-gh-guard.sh and use its quota checks. Required GitHub reads go through .claude/bin/super-board-github-read.py; a read that misses its --kind shape exits 64 for that call only and prints the valid form, so fix the read. Check --check before new writes, migrations and merges; exit 79 means status=halted, no more GitHub calls, preserve claims/worktree/card/approval. Never retry a mutation.
Use .claude/bin/super-board-card.sh for board reads/moves and .claude/bin/super-board-pr-body.sh for owned PR blocks; follow writing-standard.md and pr-author-notes.md.
Use your own worktree under .claude/worktrees/; never edit the main checkout. Clean up on ordinary exit, preserve work on halt/interruption.
You are running inside the OpenCode agent harness with real tools (bash, edit, read, grep, …). Do the work with them — never just describe it. Perform preflight, classification and truth-check duties yourself; do not assume a sub-agent exists. This changes the execution host, never the evidence requirements, confidence threshold or merge policy. This lane never owns Review or merge.
Return ONLY a JSON object as your FINAL message, no prose: status=advanced|bounced|blocked|failed|halted; column=current board column; detail=one line; prUrl/branch when known, otherwise null.
'''
if args.lane == 'build':
    prompt += '''Before creating any worktree or changing code, perform run.md's Builder pre-flight inline: call super-board-preflight.sh, judge its candidates semantically, and act on proceed/hold/sequence/skipped. Blind preflight leaves Ready and returns failed. Your own issue branch PR is not a duplicate. Read the issue and all comments; preserve qa/bug/feature labels. If untyped, classify feature or bug and add that label, never qa. Then follow the Builder lifecycle.
'''
elif args.lane == 'qa' and card['status'] == 'Ready':
    prompt += 'This qa-labelled Ready card skips Building: move Ready → QA and create the issue branch from the base; test the existing product per run.md qa cards.\n'


def interrupted(signum, frame):
    result('halted', 'lane interrupted; preserve claims and worktrees')
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)


def collect_text(raw):
    chunks = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get('type') == 'text':
            part = event.get('part') or {}
            text = part.get('text')
            if isinstance(text, str):
                chunks.append(text)
    return '\n'.join(chunks)


def last_json_object(text):
    text = text.strip()
    try:
        return json.loads(text)
    except ValueError:
        pass
    depth = 0
    start = None
    candidate = None
    for i, ch in enumerate(text):
        if ch == '{':
            if depth == 0:
                start = i
            depth += 1
        elif ch == '}' and depth:
            depth -= 1
            if depth == 0 and start is not None:
                candidate = text[start:i + 1]
    if candidate:
        try:
            return json.loads(candidate)
        except ValueError:
            return None
    return None


try:
    completed = subprocess.run(
        [opencode, 'run', '--dangerously-skip-permissions', '-m', model, '--format', 'json', prompt],
        cwd=str(root), capture_output=True, text=True,
        timeout=float(os.environ.get('SUPER_BOARD_LANE_TIMEOUT', '1800')))
except subprocess.TimeoutExpired:
    result('failed', 'OpenCode lane timed out')
    sys.exit(1)
except OSError as error:
    result('failed', f'could not start OpenCode: {error}')
    sys.exit(1)

text = collect_text(completed.stdout)
parsed = last_json_object(text)
if (not isinstance(parsed, dict)
        or parsed.get('status') not in ['advanced', 'bounced', 'blocked', 'failed', 'halted']
        or not all(isinstance(parsed.get(key), str) for key in ['column', 'detail'])):
    tail = (completed.stderr or text or f'exit {completed.returncode}').strip().replace('\n', ' ')[-200:]
    result('failed', f'OpenCode returned no valid lane result: {tail}')
    sys.exit(1)
print(json.dumps(parsed))
sys.exit(79 if parsed['status'] == 'halted' else 0)
PY
