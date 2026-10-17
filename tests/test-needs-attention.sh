#!/usr/bin/env bash
# No-provider visibility — a lane that cannot get a provider writes a throttled attention entry.
# Offline: the runner is sourced with SB_LIB_ONLY; lane_provider is stubbed to fail.
#
#   bash tests/test-needs-attention.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n   expected: %s\n   actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

mkdir -p "$TMP/.claude/super-board"
export SB_GITHUB_RETRY_DELAY=0
export SB_LIB_ONLY=1
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/super-board-run.sh"
set +e

# The work happens relative to the current directory, like a real tick.
cd "$TMP"

lane_provider() { return 1; }   # no provider for any lane
issue_locked() { return 1; }

dispatch_lane build 1 >/dev/null 2>&1
ATT="$TMP/.claude/super-board/needs-attention.log"
is "an attention entry is written" "yes" "$([ -f "$ATT" ] && echo yes || echo no)"
is "it names the lane and card" "1" "$(grep -c 'lane=build issue=#1' "$ATT" 2>/dev/null || echo 0)"

dispatch_lane qa 2 >/dev/null 2>&1
is "a second failure inside the window is throttled to one line" "1" "$(grep -c . "$ATT" 2>/dev/null || echo 0)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
