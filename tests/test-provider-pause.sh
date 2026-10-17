#!/usr/bin/env bash
# Provider-pause policy — a recovered vendor clears after the TTL instead of staying parked.
# Offline: the runner is sourced with SB_LIB_ONLY; usage/probe are stubbed.
#
#   bash tests/test-provider-pause.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n   expected: %s\n   actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

export SB_PROVIDER_PAUSE_DIR="$TMP/pauses"
mkdir -p "$SB_PROVIDER_PAUSE_DIR"
export SB_GITHUB_RETRY_DELAY=0
export SB_LIB_ONLY=1
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/super-board-run.sh"
set +e

# An unreadable plan snapshot is the normal Claude/Codex case: it must not imply exhaustion.
provider_usage_check() { echo '{"state":"unknown","reason":"stub"}'; return 3; }
provider_limit_log() { return 1; }

pause_provider claude "unit test"
is "pause file created" "yes" "$([ -f "$SB_PROVIDER_PAUSE_DIR/claude" ] && echo yes || echo no)"

SB_PAUSE_TTL=1800
provider_dispatch_allowed claude >/dev/null 2>&1
is "a fresh pause blocks the provider" "1" "$?"

printf '{"at":%s,"source":"test","reason":"old"}' "$(( $(date +%s) - 10 ))" \
  > "$SB_PROVIDER_PAUSE_DIR/claude"
SB_PAUSE_TTL=1
provider_dispatch_allowed claude >/dev/null 2>&1
is "an expired pause allows the provider" "0" "$?"
is "the expired pause file is removed" "no" "$([ -f "$SB_PROVIDER_PAUSE_DIR/claude" ] && echo yes || echo no)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
