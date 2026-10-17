#!/usr/bin/env bash
# Block-class policy — the sweep may free a card only when its own condition
# verifies, and never a human block. Offline: the runner is sourced with
# SB_LIB_ONLY; issue/provider/CI state is stubbed.
#
#   bash tests/test-block-classes.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n   expected: %s\n   actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

export SB_LIB_ONLY=1
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/super-board-run.sh"
set +e

# #2 is Done on the board, #3 is open, #9 is unreadable (halt).
PROJECT_ITEMS_JSON='{"items":[{"content":{"number":2,"type":"Issue"},"status":"Done"},{"content":{"number":3,"type":"Issue"},"status":"Todo"}]}'
issue_is_open() { case "$1" in 2) return 1 ;; 3) return 0 ;; *) return 79 ;; esac; }
lane_provider() { [ "$1" = build ] && return 0; return 1; }
ci_sha_green() { [ "$1" = abc1234 ]; }

met() { resume_when_met "$@" >/dev/null 2>&1; echo $?; }

is "dependency: every blocker closed or Done" "0" "$(met dependency issues-closed:2 2)"
is "dependency: an open blocker holds it" "1" "$(met dependency issues-closed:3 3)"
is "dependency: an unreadable blocker holds it" "1" "$(met dependency issues-closed:9 9)"
is "legacy dependency: empty blocked-by holds it" "1" "$(met dependency '' '')"
is "legacy dependency: dash is a human gate" "1" "$(met dependency '' '-')"
is "transient after: a past instant is due" "0" "$(met transient after:2020-01-01T00:00:00Z -)"
is "transient after: a future instant waits" "1" "$(met transient after:2999-01-01T00:00:00Z -)"
is "transient provider-available: the lane has one" "0" "$(met transient provider-available:build -)"
is "transient provider-available: none for the lane" "1" "$(met transient provider-available:review -)"
is "transient ci-rerun: green checks clear it" "0" "$(met transient ci-rerun:abc1234 -)"
is "transient ci-rerun: red checks hold it" "1" "$(met transient ci-rerun:deadbee -)"
is "transient issues-closed: same rule as dependency" "0" "$(met transient issues-closed:2 -)"
is "transient never: never resumes" "1" "$(met transient never -)"

# Human blocks are the sweep's hard stop, whatever they claim.
is "human: human-done waits for the person" "1" "$(met human human-done -)"
is "human: a provider condition does not override the class" "1" "$(met human provider-available:build -)"
is "unknown class: fail safe" "1" "$(met weird after:2020-01-01 -)"

# The machine lines are read the way lanes actually write them.
is "machine_line keeps a multi-word tag" "🛡 Safety / destructive" \
   "$(machine_line $'Reason tag:  🛡 Safety / destructive\nblocked-by: -' 'Reason tag')"
is "machine_line is case-insensitive" "3" "$(machine_line $'BLOCK-CLASS: transient\nAttempts: 3' 'attempts')"
is "machine_line takes the last line" "human" "$(machine_line $'block-class: transient\nblock-class: human' 'block-class')"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
