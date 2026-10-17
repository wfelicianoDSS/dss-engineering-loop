#!/usr/bin/env bash
# super-board-autostart.sh — start the FieldOps board on a schedule.
#
# Called by cron at 07:00. Uses Claude first (fresh quota window), falls back to Codex via
# super-board-guard.sh, and stops when Codex usage is exhausted. Mirrors what the user asked for:
# "run first Claude usage and finish when Codex usage is done".
set -u
export PATH="$HOME/.local/bin:$HOME/.local/node/bin:$HOME/.opencode/bin:$HOME/.dotnet:$PATH"
cd "$HOME/fieldops" || exit 1
CFG=".claude/super-board/configs/fieldops.json"

echo "[$(date -u +%FT%TZ)] autostart" >> /tmp/board-autostart.log

# Claude-first at the start of a fresh quota window
python3 - "$CFG" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d['lane_backend'] = 'claude'; p.write_text(json.dumps(d, indent=2) + "\n")
print("lane_backend=claude")
PY

# Reconcile a stale READ halt (idempotent — it re-runs the recorded read and archives
# the record on success). A MUTATION halt is deliberately left in place: `--resume`
# refuses it and its evidence must be reconciled by a human or the watchdog's fix
# agent, never deleted. (The old `rm -f github-halt*.json` destroyed that evidence.)
if [ -f .claude/super-board/github-halt.json ]; then
  echo "[$(date -u +%FT%TZ)] reconciling stale github-halt via --resume" >> /tmp/board-autostart.log
  python3 .claude/bin/super-board-github-read.py --resume >> /tmp/board-autostart.log 2>&1 || true
fi

# The runner refuses to start on a drifted checkout (exit 73). Autostart syncs the
# base branch itself, but only when the tree is clean — local edits are never discarded.
BASE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("base_branch","main"))' "$CFG" 2>/dev/null || echo main)
CURRENT=$(git branch --show-current 2>/dev/null || true)
if [ -n "$CURRENT" ] && [ "$CURRENT" != "$BASE" ] && [ -z "$(git status --porcelain)" ]; then
  echo "[$(date -u +%FT%TZ)] syncing checkout ${CURRENT} → ${BASE}" >> /tmp/board-autostart.log
  git fetch origin --prune >> /tmp/board-autostart.log 2>&1 \
    && git checkout -f -B "$BASE" "origin/$BASE" >> /tmp/board-autostart.log 2>&1 || true
fi

if pgrep -f "super-board-run.sh fieldops" >/dev/null 2>&1; then
  echo "[$(date -u +%FT%TZ)] runner already running — not starting another" >> /tmp/board-autostart.log
  exit 0
fi

: > /tmp/sb-run.log
nohup .claude/bin/super-board-run.sh fieldops >> /tmp/sb-run.log 2>&1 &
echo $! > /tmp/sb-run.pid
pkill -f 'super-board-guard.sh' 2>/dev/null || true
nohup .claude/bin/super-board-guard.sh >> /tmp/board-guard.log 2>&1 &
echo $! > /tmp/board-guard.pid
echo "[$(date -u +%FT%TZ)] started runner pid=$(cat /tmp/sb-run.pid) guard pid=$(cat /tmp/board-guard.pid)" >> /tmp/board-autostart.log
