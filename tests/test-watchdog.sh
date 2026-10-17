#!/usr/bin/env bash
# Watchdog stall escalation — an idle runner with pending work is restarted twice, then
# escalated once to needs-attention.log; no LLM fix agent is ever dispatched. A quota
# freeze (runner down, both providers limited) restarts nothing and escalates nothing.
# Offline: pgrep/pkill/probe are PATH stubs; SB_WATCHDOG_TMP isolates all scratch state.
#
#   bash tests/test-watchdog.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n   expected: %s\n   actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
count() { local n; n=$(grep -c "$1" "$2" 2>/dev/null) || true; printf '%s' "${n:-0}"; }
lines() { count . "$1"; }

REPO="$TMP/repo"
STATE="$TMP/state"
mkdir -p "$REPO/.claude/super-board/configs" "$REPO/.claude/bin" "$REPO/docs/super-board" \
         "$TMP/bin" "$STATE" "$TMP/home"
printf '{"lane_backend":"claude"}\n' > "$REPO/.claude/super-board/configs/fieldops.json"

# The board has work waiting in two columns.
cat > "$REPO/.claude/bin/super-board-card.sh" <<'SH'
#!/usr/bin/env bash
printf '{"items":[{"status":"Ready"},{"status":"Review"}]}\n'
SH
# A restart spawns these in the background; they exit immediately.
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO/.claude/bin/super-board-run.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO/.claude/bin/super-board-guard.sh"

# ── PATH stubs ────────────────────────────────────────────────────────────────
# pgrep: runner up/down; no live workers.
cat > "$TMP/bin/pgrep" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *-fc*) printf '0\n'; exit 0 ;;
  *"super-board-run.sh fieldops"*)
    [ "${SB_TEST_RUNNER_UP:-1}" = 1 ] && { printf '4242\n'; exit 0; }; exit 1 ;;
  *) exit 1 ;;
esac
SH
# pkill: record every kill instead of performing it.
cat > "$TMP/bin/pkill" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SB_TEST_PKILL"
exit 0
SH
# probe: available, or hit a vendor limit.
cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
[ "${SB_TEST_LIMITED:-0}" = 1 ] && { printf "You've hit your usage limit\n"; exit 1; }
printf 'OK\n'
SH
cp "$TMP/bin/claude" "$TMP/bin/codex"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/flock"
printf '#!/usr/bin/env bash\nshift; exec "$@"\n' > "$TMP/bin/timeout"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/sleep"
chmod +x "$TMP/bin/"*

RUNNER_UP=1
LIMITED=0
tick() {
  env -u SB_NOTIFY_WEBHOOK -u RESEND_API_KEY -u RESEND_FROM -u NOTIFY_TO \
      HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
      SB_REPO_PATH="$REPO" SB_WATCHDOG_TMP="$STATE" \
      SB_NOTIFY_ENV="$TMP/no-notify.env" \
      SB_TEST_RUNNER_UP="$RUNNER_UP" SB_TEST_LIMITED="$LIMITED" SB_TEST_PKILL="$TMP/pkill.log" \
      bash "$REPO_ROOT/scripts/super-board-watchdog.sh" >/dev/null 2>&1
}
restarts() { count 'super-board-run.sh fieldops' "$TMP/pkill.log"; }
ATT="$REPO/.claude/super-board/needs-attention.log"
LOG="$REPO/docs/super-board/watchdog.log"

# ── one stall is not enough ───────────────────────────────────────────────────
tick
is "the first stalled check restarts nothing" "0" "$(restarts)"
is "the first stalled check escalates nothing" "0" "$(lines "$ATT")"

# ── stalled twice: restart, never escalate on the first incident ──────────────
tick
is "a second consecutive stall restarts the runner once" "1" "$(restarts)"
is "the first incident adds no attention entry" "0" "$(lines "$ATT")"

# ── a second incident restarts again, still no escalation ─────────────────────
tick; tick
is "a second incident restarts again" "2" "$(restarts)"
is "two restarts still add no attention entry" "0" "$(lines "$ATT")"

# ── a restart that did not help escalates once and stops restarting ───────────
tick; tick
is "the third incident escalates to needs-attention.log" "1" "$(lines "$ATT")"
is "the escalation names the unresolved stall" "1" \
   "$(grep -c 'still idle' "$ATT" 2>/dev/null || true)"
is "escalation does not restart a fourth time" "2" "$(restarts)"
is "no fix agent is left running" "no" \
   "$([ -f "$STATE/sb-watchdog-fixer.pid" ] && echo yes || echo no)"
is "the owner note is written" "yes" \
   "$([ -f "$REPO/docs/super-board/NEEDS-ATTENTION.md" ] && echo yes || echo no)"

# ── a quota freeze is not a liveness failure ──────────────────────────────────
RUNNER_UP=0
LIMITED=1
tick
is "a quota freeze restarts nothing" "2" "$(restarts)"
is "a quota freeze escalates nothing" "1" "$(lines "$ATT")"
is "it logs that it is waiting for quota" "1" \
   "$(grep -c 'waiting quietly' "$LOG" 2>/dev/null || true)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
