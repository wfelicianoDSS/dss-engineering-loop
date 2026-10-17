#!/usr/bin/env bash
# Lease v2 — heartbeat, stale-live-pid escalation and the unchanged dead-pid path.
# Offline; sources the runner with SB_LIB_ONLY and uses a real sleep process for liveness.
#
#   bash tests/test-lease.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n   expected: %s\n   actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

export SB_LIB_ONLY=1
export SB_GITHUB_HALT_FILE="$TMP/halt.json"
export INFLIGHT_DIR="$TMP/inflight"
export WORKER_LOG_DIR="$TMP/logs"
mkdir -p "$INFLIGHT_DIR" "$WORKER_LOG_DIR"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/super-board-run.sh"
set +e
BOT_LOGIN=""
LEASE_TTL=2700

# 1 — a legacy single-PID lock still parses; a v2 lock exposes heartbeat/head.
printf '4242\n' > "$INFLIGHT_DIR/1"
read_lock 1
is "legacy lock parses PID" "4242" "$PID"
is "legacy lock has no heartbeat" "" "$HEARTBEAT"

# 2 — --check rewrites HEARTBEAT only when SB_LEASE_FILE names a v2 lease.
sleep 30 & LIVE=$!
printf 'PID=%s\nLANE=build\nPHASE=build\nSTARTED=x\nHEARTBEAT=1\nHEAD=-\nPROVIDER=claude\n' "$LIVE" > "$INFLIGHT_DIR/2"
python3 "$REPO_ROOT/scripts/super-board-github-read.py" --check
is "no SB_LEASE_FILE leaves HEARTBEAT alone" "HEARTBEAT=1" "$(grep '^HEARTBEAT=' "$INFLIGHT_DIR/2")"
SB_LEASE_FILE="$INFLIGHT_DIR/2" python3 "$REPO_ROOT/scripts/super-board-github-read.py" --check
HB=$(grep '^HEARTBEAT=' "$INFLIGHT_DIR/2" | cut -d= -f2)
[ "${HB:-0}" -gt 1 ] && ok "--check refreshes HEARTBEAT" || bad "heartbeat refreshed" ">1" "$HB"

# 3 — live pid, heartbeat older than TTL: one attention line, worker kept.
rm -f "$INFLIGHT_DIR/2"   # its deliberately ancient heartbeat would trip the 2× kill
sleep 60 & LIVE=$!
NOW=$(date +%s)
printf 'PID=%s\nLANE=qa\nPHASE=qa\nSTARTED=x\nHEARTBEAT=%s\nHEAD=-\nPROVIDER=claude\n' "$LIVE" "$((NOW - 3000))" > "$INFLIGHT_DIR/3"
reap_finished_locks
[ -f "$INFLIGHT_DIR/3" ] && ok "a stale-but-alive lease is kept at 1×TTL" || bad "lease kept" "present" "missing"
grep -q "heartbeat stale" "$TMP/needs-attention.log" 2>/dev/null && ok "stale heartbeat is visible" || bad "attention written" "heartbeat stale" "absent"
kill -0 "$LIVE" 2>/dev/null && ok "worker is not killed at 1×TTL" || bad "worker alive" "alive" "dead"

# 4 — live pid, heartbeat older than 2×TTL: terminate, release, keep worktree.
printf 'PID=%s\nLANE=qa\nPHASE=qa\nSTARTED=x\nHEARTBEAT=%s\nHEAD=-\nPROVIDER=claude\n' "$LIVE" "$((NOW - 6000))" > "$INFLIGHT_DIR/4"
reap_finished_locks
sleep 0.2
kill -0 "$LIVE" 2>/dev/null && bad "hung worker terminated" "dead" "alive" || ok "hung worker terminated at 2×TTL"
[ ! -f "$INFLIGHT_DIR/4" ] && ok "hung lease released" || bad "lease released" "missing" "present"

# 5 — dead pid: the old path still removes the lock immediately.
printf 'PID=999999\nLANE=review\nPHASE=review\nSTARTED=x\nHEARTBEAT=%s\nHEAD=-\nPROVIDER=codex\n' "$NOW" > "$INFLIGHT_DIR/5"
reap_finished_locks
[ ! -f "$INFLIGHT_DIR/5" ] && ok "dead-pid lease reaped" || bad "dead-pid lease reaped" "missing" "present"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
