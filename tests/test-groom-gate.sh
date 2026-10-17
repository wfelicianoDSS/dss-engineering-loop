#!/usr/bin/env bash
# Groom gate policy — groom only when the backlog changed or the cooldown elapsed, and only
# while Ready is at/below the floor. Offline; sources the runner with SB_LIB_ONLY.
#
#   bash tests/test-groom-gate.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n   expected: %s\n   actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

export SB_LIB_ONLY=1 SB_GITHUB_RETRY_DELAY=0
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/super-board-run.sh"
set +e

GROOM_ENABLED=true
GROOM_READY_FLOOR=1
GROOM_COOLDOWN=1800
READY=0

groom_due "156:550" "" 0 0;              is "changed backlog → groom" "0" "$?"
groom_due "156:550" "156:550" 100 200;   is "unchanged inside cooldown → skip" "1" "$?"
groom_due "156:550" "156:550" 100 2000;  is "unchanged after cooldown → groom" "0" "$?"
READY=2; groom_due "156:550" "" 0 0;     is "Ready above floor → skip" "1" "$?"
READY=0; GROOM_ENABLED=false; groom_due "156:550" "" 0 0; is "disabled → skip" "1" "$?"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
