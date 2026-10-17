#!/usr/bin/env bash
# super-board-watchdog.sh — keep the board running; self-heal mechanical failures;
# escalate only what it cannot fix; wait quietly when providers are out of quota.
#
# Runs from cron every few minutes. Playbook:
#   1. A deliberate gate is preserved, never deleted:
#        - github-halt.json (a GitHub write that needs reconciling): after
#          SB_HALT_ESCALATE_CHECKS consecutive checks it is handed to a fresh fix
#          agent ("message an agent", not silent deletion).
#        - provider-pauses/* (vendor quota): wait quietly; the runner/autostart owns
#          clearing these when the provider's window resets.
#   2. Self-heal (only when no gate is present): dedupe duplicate runners/guards,
#      re-assert Claude-first config drift, check repo-RAG/Docker health.
#   3. If the runner is alive and healthy -> do nothing.
#   4. If the runner is DOWN: probe Claude then Codex with a tiny call.
#        - both limited -> log "waiting on quota" and DO NOTHING (per policy).
#        - otherwise    -> preserve evidence, restart an ungated runner Claude-first.
#   5. If the runner is alive but STALLED (work pending, no workers, no halt, not
#      quota) for two consecutive checks -> restart it; if it stalls again ->
#      dispatch a fix agent.
#
# It never sends repository content anywhere. Notification is best-effort: a note file,
# plus an optional SB_NOTIFY_WEBHOOK POST.
set -u
export PATH="$HOME/.local/bin:$HOME/.local/node/bin:$HOME/.opencode/bin:$HOME/.dotnet:$PATH"
cd "${SB_REPO_PATH:-$HOME/fieldops}" || exit 0
CFG=".claude/super-board/configs/fieldops.json"
SB_READ=".claude/bin/super-board-github-read.py"
STATE_DIR=".claude/super-board"
LOG="docs/super-board/watchdog.log"; NOTE="docs/super-board/NEEDS-ATTENTION.md"
RESTART_STATE="/tmp/sb-watchdog-restarts.state"
STATE="/tmp/sb-watchdog.state"; WLOG="/tmp/board-watchdog.log"
GATE_STATE="/tmp/sb-watchdog-gate.state"
LOOP_STATE="/tmp/sb-watchdog-loop.state"
FIXER_PID="/tmp/sb-watchdog-fixer.pid"; FIXER_LOG="/tmp/sb-watchdog-fixer.log"
HALT_ESCALATE_CHECKS="${SB_HALT_ESCALATE_CHECKS:-6}"
DRY_RUN=0; [ "${1:-}" = "--dry-run" ] && DRY_RUN=1
HOST="$(hostname 2>/dev/null || echo unknown)"
# Optional email notification credentials (Resend), kept OUTSIDE the repo at
# ~/.config/super-board/notify.env (chmod 600). Missing file → email simply not attempted.
NOTIFY_ENV="${SB_NOTIFY_ENV:-$HOME/.config/super-board/notify.env}"
if [ -f "$NOTIFY_ENV" ]; then . "$NOTIFY_ENV" 2>/dev/null || true; fi

mkdir -p docs/super-board
log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$HOST" "$*" | tee -a "$WLOG" >> "$LOG"; }
notify() { # $1 = subject, $2 = body
  printf '# %s\n\n_%s (%s)_\n\n%s\n' "$1" "$(date -u +%FT%TZ)" "$HOST" "$2" > "$NOTE"
  if [ -n "${SB_NOTIFY_WEBHOOK:-}" ]; then
    curl -sS -m 10 -X POST "$SB_NOTIFY_WEBHOOK" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg t "$1" --arg b "$2" '{text:("🛠 super-board: "+$t+"\n"+$b)}')" >/dev/null 2>&1 || true
  fi
  # Email the same alert via Resend when credentials are present (never prints the key).
  if [ -n "${RESEND_API_KEY:-}" ] && [ -n "${RESEND_FROM:-}" ] && [ -n "${NOTIFY_TO:-}" ]; then
    curl -sS -m 15 -X POST https://api.resend.com/emails \
      -H "Authorization: Bearer $RESEND_API_KEY" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg from "$RESEND_FROM" --arg to "$NOTIFY_TO" --arg s "🛠 super-board: $1" --arg b "$2" \
            '{from:$from,to:[$to],subject:$s,text:$b}')" >/dev/null 2>&1 || true
  fi
}
runner_up() { pgrep -f "super-board-run.sh fieldops" >/dev/null 2>&1; }
worker_count() { local n; n=$(pgrep -fc 'super-board run' 2>/dev/null) || true; printf '%s' "${n:-0}"; }
probe() { # $1 = claude|codex -> 0 available, 1 limited
  local out
  if [ "$1" = claude ]; then
    out=$(timeout 70 claude -p "reply OK" --output-format text 2>&1)
  else
    out=$(timeout 100 codex exec -s danger-full-access "reply OK" 2>&1)
  fi
  printf '%s' "$out" | grep -qiE "You.ve hit your (session|usage) limit|chatgpt.com/explore/pro|usage limit reached" && return 1
  printf '%s' "$out" | grep -qiE "OK" && return 0
  return 1
}
PROBE_CACHE=" "
probe_cached() { # memoize probe() so a tick never probes a provider twice
  case "$PROBE_CACHE" in *" p_$1=ok "*) return 0 ;; *" p_$1=no "*) return 1 ;; esac
  if probe "$1"; then PROBE_CACHE="$PROBE_CACHE p_$1=ok "; return 0; fi
  PROBE_CACHE="$PROBE_CACHE p_$1=no "; return 1
}
pending_work() {
  local n
  n=$(bash .claude/bin/super-board-card.sh --config "$CFG" items 2>/dev/null \
    | jq '[.items[]|select(.status|IN("Ready","Building","QA","Review"))]|length' 2>/dev/null) || true
  printf '%s' "${n:-0}"
}
provider_pause_file() { printf '%s/provider-pauses/%s' "$STATE_DIR" "$1"; }
provider_paused() {
  # Vendor quota freeze: only when BOTH binding providers are paused. Freezing on
  # *any* pause file left the watchdog idle for a whole day while Claude was
  # available and only codex was paused (2026-10-15). A paused fallback must not
  # stop the watchdog from self-healing onto the provider that *is* available.
  [ -f "$(provider_pause_file claude)" ] && [ -f "$(provider_pause_file codex)" ]
}
# Lane-loop guard: the same card dispatched to the same lane 3+ times in the recent
# manifest is a stalled loop (a stale policy/gate re-rejecting a good PR), not progress.
# This is exactly what burned a full Claude window on 2026-10-15. Alert once per
# signature instead of silently re-billing a full review every re-dispatch.
loop_alert() {
  local manifest="docs/super-board/runs/$(date +%F)-fieldops.md" sig
  [ -f "$manifest" ] || return 0
  sig=$(tail -n 500 "$manifest" 2>/dev/null \
    | grep -oE 'dispatch lane=[a-z0-9]+ issue=#[0-9]+' | sort | uniq -c \
    | awk '$1>=3 {print $3" "$4}' | tr '\n' ';')
  [ -n "$sig" ] || return 0
  [ "$(cat "$LOOP_STATE" 2>/dev/null)" = "$sig" ] && return 0
  printf '%s' "$sig" > "$LOOP_STATE" 2>/dev/null || true
  log "loop guard: repeated dispatch — ${sig}"
  notify "lane loop detected" "Same card re-dispatched 3+ times in the recent manifest: ${sig}. Likely a stale policy/gate re-rejecting a completed review — compare the card branch's .claude/ against the base."
}

# ── self-heal helpers (safe, idempotent, never delete evidence) ───────────────
worker_owner_runners() {
  # PIDs of runners that are the parent of a live board worker.
  local w pp
  pgrep -f 'super-board run' 2>/dev/null | while read -r w; do
    pp=$(ps -o ppid= -p "$w" 2>/dev/null | tr -d ' ')
    [ -n "$pp" ] && echo "$pp"
  done | sort -u
}
dedupe_runners() {
  # Two runners scanning one board (same repo dir) double-dispatch and fight over
  # restarts. Keep the one that owns a live worker, else the oldest; terminate the
  # rest. Runners in other directories (other boards/worktrees) are never touched.
  local keep p n pp owner pids=()
  for p in $(pgrep -f "super-board-run.sh fieldops" 2>/dev/null | sort -n); do
    [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$PWD" ] && pids+=("$p")
  done
  n=${#pids[@]}
  [ "$n" -gt 1 ] || return 0
  keep=""
  for owner in $(worker_owner_runners); do
    for p in "${pids[@]}"; do [ "$p" = "$owner" ] && { keep="$p"; break 2; }; done
  done
  [ -n "$keep" ] || keep="${pids[0]}"
  for p in "${pids[@]}"; do
    [ "$p" = "$keep" ] && continue
    pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    log "self-heal: duplicate runner pid=$p (ppid=${pp:-?}) — terminating (keeping $keep)"
    [ "$DRY_RUN" -eq 1 ] || kill -TERM "$p" 2>/dev/null || true
  done
}
dedupe_guards() {
  local keep p n pids=()
  for p in $(pgrep -f "super-board-guard.sh" 2>/dev/null | sort -n); do
    [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$PWD" ] && pids+=("$p")
  done
  n=${#pids[@]}
  [ "$n" -gt 1 ] || return 0
  keep="${pids[0]}"
  for p in "${pids[@]}"; do
    [ "$p" = "$keep" ] && continue
    log "self-heal: duplicate guard pid=$p — terminating (keeping $keep)"
    [ "$DRY_RUN" -eq 1 ] || kill -TERM "$p" 2>/dev/null || true
  done
}
reassert_claude_first() {
  # Claude-first is the locked policy. The runner only flips to codex while Claude
  # is paused; a codex lane_backend with no Claude pause and Claude available again
  # is drift, so restore it.
  local cur
  cur=$(jq -r '.lane_backend // "claude"' "$CFG" 2>/dev/null || echo claude)
  [ "$cur" = "claude" ] && return 0
  [ -f "$(provider_pause_file claude)" ] && return 0
  probe_cached claude || return 0
  log "self-heal: lane_backend=$cur but Claude is available and unpaused — re-asserting Claude-first"
  [ "$DRY_RUN" -eq 1 ] && return 0
  python3 - "$CFG" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d['lane_backend'] = 'claude'
d.setdefault('groom', {})['backend'] = 'claude'
p.write_text(json.dumps(d, indent=2) + "\n")
PY
}
docker_health() {
  # repo-RAG vector mode needs Docker; without it lanes silently fall back to
  # keyword search. Detect and best-effort start it (never block the tick).
  [ -f .claude/repo-rag/compose.yml ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 && return 0
  log "self-heal: Docker is down — repo-RAG lanes fall back to keyword search"
  [ "$DRY_RUN" -eq 1 ] && return 0
  (docker desktop start >/dev/null 2>&1 || true) &
}

restart_board() { # $1 = reason
  log "restart: $1"
  # Never discard worker evidence or claims during an idle-runner restart.
  [ "$(worker_count)" -eq 0 ] || return 1
  [ ! -f "$STATE_DIR/github-halt.json" ] || return 1
  provider_paused && return 1
  pkill -f "super-board-run.sh fieldops" 2>/dev/null || true
  pkill -f 'super-board-guard.sh' 2>/dev/null || true
  sleep 3
  python3 - "$CFG" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d['lane_backend'] = 'claude'; d.setdefault('groom', {})['backend'] = 'claude'
p.write_text(json.dumps(d, indent=2) + "\n")
PY
  : > /tmp/sb-run.log
  nohup .claude/bin/super-board-run.sh fieldops >> /tmp/sb-run.log 2>&1 9>&- &
  echo $! > /tmp/sb-run.pid
  nohup .claude/bin/super-board-guard.sh >> /tmp/board-guard.log 2>&1 9>&- &
  echo $! > /tmp/board-guard.pid
  sleep 25
  runner_up
}
dispatch_fixer() { # $1 = diagnostics
  # Owner rule (2026-10-16): board / control-plane fixes belong to the orchestrator and
  # must NEVER be done by Codex or Claude. Do not dispatch an LLM fix agent; escalate.
  log "board needs the orchestrator — fix agents are disabled (owner rule): $1"
  printf '%s watchdog escalation: %s\n' "$(date -u +%FT%TZ)" "$1" \
    >> "${STATE_DIR:-$HOME/fieldops/.claude/super-board}/needs-attention.log" 2>/dev/null || true
  notify "watchdog: board needs the orchestrator (fix agents disabled)" "$1"
}
escalate_github_halt() {
  # A github-halt is a write that may or may not have landed — it needs reconciling,
  # not a blind restart. Preserve it; after SB_HALT_ESCALATE_CHECKS checks, ask a fix
  # agent to reconcile it. Evidence is never deleted by the watchdog.
  local n reason
  n=$(( $(cat "$GATE_STATE" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$GATE_STATE" 2>/dev/null || true
  reason=$(cat "$STATE_DIR/github-halt.json" 2>/dev/null | tr -d '\n' | cut -c1-300)
  log "github-halt present — preserving state (check ${n}/${HALT_ESCALATE_CHECKS}): ${reason:-unknown}"
  [ "$n" -ge "$HALT_ESCALATE_CHECKS" ] || return 0
  echo 0 > "$GATE_STATE" 2>/dev/null || true
  dispatch_fixer "persistent github-halt for ${n} consecutive checks: ${reason:-unknown}. Reconcile the pending GitHub write recorded in ${STATE_DIR}/github-halt.json against GitHub, then remove the halt file and restart the runner Claude-first."
}

# ── main ─────────────────────────────────────────────────────────────────────
exec 9> /tmp/sb-watchdog.lock
flock -n 9 || exit 0

# A deliberate github-halt is not a liveness failure. Distinguish the two kinds:
#   * a READ halt (the record carries the operation) is idempotent — re-running it has
#     no side effects, so a transient timeout can be auto-resumed. Without this the
#     runner exits and nothing re-runs the read, so the board stalls until a human or
#     the fix agent reconciles a purely transient failure.
#   * a MUTATION halt (no operation; `--resume` itself refuses it) needs human
#     reconciliation — escalate, never auto-clear.
# The watchdog never deletes evidence: `--resume` archives the halt on success and we
# only continue when it is actually gone.
if [ -f "$STATE_DIR/github-halt.json" ]; then
  if [ "$DRY_RUN" -eq 0 ] && jq -e '.operation != null' "$STATE_DIR/github-halt.json" >/dev/null 2>&1; then
    log "github-halt is a read failure — attempting an idempotent --resume"
    python3 "$SB_READ" --resume >/dev/null 2>&1 || true
  fi
  if [ -f "$STATE_DIR/github-halt.json" ]; then
    escalate_github_halt
    echo 0 > "$STATE"
    exit 0
  fi
  log "github-halt cleared by --resume — continuing to restart the board"
fi
echo 0 > "$GATE_STATE" 2>/dev/null || true
loop_alert

# A provider pause is quota, not liveness: policy is to wait, never restart through it.
if provider_paused; then
  log "board paused by evidence gate — preserving state; no restart"
  echo 0 > "$STATE"
  exit 0
fi

# No gate: run the safe self-heal playbook before judging liveness.
dedupe_runners; dedupe_guards
docker_health

if runner_up; then
  if [ "$(worker_count)" -ge 1 ]; then echo 0 > "$STATE"; echo 0 > "$RESTART_STATE"; exit 0; fi   # lanes busy -> healthy
  if [ "$(pending_work)" -eq 0 ]; then echo 0 > "$STATE"; echo 0 > "$RESTART_STATE"; exit 0; fi   # nothing to do
  stalled=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
  echo "$stalled" > "$STATE"
  log "runner up but idle with $(pending_work) pending card(s) (stalled check ${stalled})"
  if [ "$stalled" -ge 2 ]; then
    reassert_claude_first
    if probe_cached claude || probe_cached codex; then
      restarts=$(cat "$RESTART_STATE" 2>/dev/null || echo 0)
      if [ "$restarts" -ge 2 ]; then
        dispatch_fixer "runner restarted ${restarts} times but still idle across subsequent checks; pending=$(pending_work)"
      else
        echo "$((restarts + 1))" > "$RESTART_STATE"
        restart_board "stalled idle with pending work and a provider available" || \
          dispatch_fixer "idle runner restart failed; pending=$(pending_work)"
      fi
      # Startup reads/claims can outlast restart_board's 25-second wait. Let the
      # next two cron checks observe recovery before declaring another stall.
      echo 0 > "$STATE"
    else
      log "idle and both providers limited — waiting for quota"
      echo 0 > "$STATE"
    fi
  fi
  exit 0
fi

# runner is DOWN
log "runner is DOWN"
reassert_claude_first
if probe_cached claude; then
  restart_board "runner down; Claude available" && log "recovered on Claude" || dispatch_fixer "runner down and restart failed (Claude available)"
elif probe_cached codex; then
  restart_board "runner down; Claude limited, Codex available" && log "recovered on Codex" || dispatch_fixer "runner down and restart failed"
else
  log "runner down and BOTH providers are out of usage — waiting quietly (7am cron will restart)"
  echo 0 > "$STATE"
fi
