#!/usr/bin/env bash
# super-board-test-mix.sh — how many NEW unit vs integration test methods a diff adds.
#
# The pyramid says: most coverage is unit, integration only at a real seam, e2e rare. When
# a PR adds more integration tests than unit tests it is usually testing pure logic through
# a database instead of in isolation — slow, and the wrong altitude. This prints the mix so
# the Builder (before opening a PR) and the Reviewer (at the gate) can see it.
#
# Read-only. Usage:
#   super-board-test-mix.sh [<base>...<head>]      # default origin/staging...HEAD
# Env: SB_REPO_PATH, SB_TEST_RANGE.
set -u
export PATH="$HOME/.local/bin:$HOME/.local/node/bin:$PATH"
cd "${SB_REPO_PATH:-$HOME/fieldops}" || exit 0
RANGE="${1:-${SB_TEST_RANGE:-origin/staging...HEAD}}"

count() { # $1 = path filter -> added [Fact]/[Theory] lines under it
  git diff "$RANGE" -- "$1" 2>/dev/null | grep -E '^\+' | grep -cE '\[(Fact|Theory)\]' || true
}
U=$(count 'tests/FieldOps.UnitTests/')
I=$(count 'tests/FieldOps.IntegrationTests/')
printf 'added test methods — unit: %s · integration: %s  (range %s)\n' "$U" "$I" "$RANGE"
if [ "$I" -gt "$U" ] && [ "$I" -gt 0 ]; then
  printf 'VERDICT: integration-heavy — a new integration test needs a real seam (wiring, a boundary, a migration); pure logic belongs in a unit test. State why in the PR body.\n'
else
  printf 'VERDICT: ok (unit >= integration, or nothing new)\n'
fi
