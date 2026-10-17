#!/usr/bin/env bash
# super-board-run.sh — headless autonomous runner.
# Spawned as `nohup scripts/super-board-run.sh <config-slug> &`.
# Pure shell while-loop. Dispatches `claude -p` workers per lane.
# Holds NO Claude session state — re-reads GitHub on every tick.
#
# Anti-zombie controls (added 2026-05-22 after #381 worker-storm incident):
#   1. Orphan scan on startup — refuses to start if super-board claude workers already running.
#   2. Issue-level lock files in .claude/super-board/inflight/<N> — survives runner restart.
#   3. Atomic GitHub assignee claim BEFORE spawning worker (closes 10-30s claude -p cold-start race).
#   4. Rate-limit guard — sleeps until reset when GraphQL remaining < 200.
#   5. Per-tick project-items cache — one gh call per tick, not per column lookup.
#   6. Tick interval bumped from 30s → 120s (GraphQL ProjectsV2 query is ~103 pts; 120s keeps usage <3.1k/hr vs 5k budget).
#   7. Lane-zombie watchdog (added 2026-05-24 after fitbox-v4 first-run hang) — kills lane PIDs whose
#      claimed issue has already moved out of the lane's expected source column. The worker's logical
#      work is done; if the claude -p process lingers, lane appears busy forever and downstream cards
#      pile up unprocessed. Uses the project-items cache so it costs zero extra API calls per tick.
#   8. Closed-issue guard (added 2026-08-06, issue #10) — a card is selected by Status column, which
#      says nothing about whether the underlying issue is still open. Before every dispatch the
#      candidate's issue state is checked; a CLOSED issue sitting in a non-terminal column is
#      reconciled to Done instead of being handed another worker.
#   9. Landed-work halt gate (added 2026-08-06, issue #8) — forward progress is measured by the set of
#      cards in Done changing, NOT by lane occupancy. A pipeline that is 100% busy but lands nothing
#      is exactly the runaway this gate must catch, so lane state no longer suppresses it.
#      Config: no_progress_cycles (default 6), max_dispatches (default 0 = unlimited).
#
# PID namespace trap (Git Bash / MSYS, issue #13): `kill -0` inside this script checks MSYS-namespace
# PIDs; PowerShell `Get-Process` checks Windows-namespace PIDs. The two disagree about the same
# process — a live worker can look dead to Windows tooling and vice versa. Always diagnose liveness
# with the same tool family that recorded the PID. Workers are started with `nohup claude -p ... &`
# (no subshell, no `exec` of a native PE), so `$!` names the worker itself rather than a bash stub.

set -euo pipefail

# Self-sufficient PATH. The runner is launched by autostart and by the watchdog (both export
# this), but also by hand — and a bare `bash super-board-run.sh <slug>` inherits a PATH without
# gh/node/claude, so the first read "could not start" and the board halted (2026-10-15). Set it
# here so every launch method works. Prepending is idempotent; the guard sources this file too.
export PATH="$HOME/.local/bin:$HOME/.local/node/bin:$HOME/.opencode/bin:$HOME/.dotnet:$PATH"

SB_GITHUB_READ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/super-board-github-read.py"
SB_GLOBAL_HALT_FILE="${SB_GITHUB_HALT_FILE:-$(pwd)/.claude/super-board/github-halt.json}"
export SB_GITHUB_GLOBAL_HALT_FILE="$SB_GLOBAL_HALT_FILE"
gh_checkpoint() { SB_GITHUB_HALT_FILE="$SB_GLOBAL_HALT_FILE" python3 "$SB_GITHUB_READ" --check || exit $?; }
card_halt_path() { printf '%s/card-halts/%s.json' "$(dirname "$SB_GLOBAL_HALT_FILE")" "$1"; }
card_issue_is_open() {
  SB_GITHUB_HALT_FILE="$(card_halt_path "$1")" issue_is_open "$1"
}
block_card_read() {
  local issue="$1" item_id="${2:-}"
  [ -n "$item_id" ] || item_id=$(echo "$PROJECT_ITEMS_JSON" | jq -r --argjson n "$issue" '.items[] | select(.content.number == $n) | .id' | head -1)
  # Reconciliation reads use the global scope, never the failed card sentinel.
  if [ -n "$item_id" ] && set_card_status "$item_id" Blocked; then
    [ -z "$BOT_LOGIN" ] || gh_write_once issue edit "$issue" --remove-assignee "$BOT_LOGIN" >/dev/null
    gh_write_once issue comment "$issue" --body "[orchestrator] [blocker] 🛑 required GitHub read failed
Did: isolated the failure to this card
✅ Done: moved to Blocked; released inflight lock; preserved worktree and read evidence
❌ Not done: required evidence unavailable
blocked-by: reconcile card read evidence in $(card_halt_path "$issue")" >/dev/null
    PROJECT_ITEMS_JSON=$(echo "$PROJECT_ITEMS_JSON" | jq --argjson n "$issue" '(.items[] | select(.content.number == $n) | .status) = "Blocked"')
    rm -f "$INFLIGHT_DIR/$issue"
    log "blocked #${issue}: required GitHub read failed; other cards continue"
  else
    log "⚠ could not move #${issue} to Blocked; preserving lock and evidence"
  fi
}

gh_write_once() {
  gh_checkpoint
  gh "$@" || {
    # Record the actual command in the halt so the failed write can be reconciled. A
    # mutation halt with no command is unreconcilable: on 2026-10-14 an `issue edit`
    # halted the board and the write it was meant to perform could not be identified.
    SB_GITHUB_HALT_FILE="$SB_GLOBAL_HALT_FILE" python3 "$SB_GITHUB_READ" --halt "GitHub 'gh $(printf '%s ' "$@")' failed; reconcile the write before restarting" >&2 || true
    exit 79
  }
}

# ───────────────────────────── args + paths ─────────────────────────────
# SB_LIB_ONLY=1 sources this file for its helpers only (gate tests). Config discovery,
# preconditions and the run loop are all skipped; the caller supplies whatever vars it needs.
CONFIG_SLUG="${1:-}"
if [ "${SB_LIB_ONLY:-0}" = "1" ]; then
  CONFIG_SLUG="${CONFIG_SLUG:-lib}"
  CONFIG_PATH="${CONFIG_PATH:-/dev/null}"
elif [ -z "$CONFIG_SLUG" ]; then
  if [ -f .claude/super-board/active ]; then
    CONFIG_SLUG=$(cat .claude/super-board/active)
  else
    echo "usage: $0 <config-slug>  (or set .claude/super-board/active)" >&2
    exit 64
  fi
fi

if [ "${SB_LIB_ONLY:-0}" != "1" ]; then
CONFIG_PATH=".claude/super-board/configs/${CONFIG_SLUG}.json"
if [ ! -f "$CONFIG_PATH" ]; then
  echo "config not found: $CONFIG_PATH" >&2
  exit 66
fi

# ───────────────────────────── config read ─────────────────────────────
# `variant` was removed in v3.0.0: one board shape, labels route cards (a Ready card
# labelled `qa` goes to the Tester, everything else to the Builder). A config still
# saying "qa-only" is refused, same as the wave planner.
VARIANT=$(jq -r '.variant // "full"' "$CONFIG_PATH")
if [ "$VARIANT" != "full" ]; then
  echo "config still says variant \"$VARIANT\" — removed in v3.0.0. Run /super-board onboard to upgrade." >&2
  exit 65
fi
PROJECT_OWNER=$(jq -r '.project.owner' "$CONFIG_PATH")
PROJECT_NUMBER=$(jq -r '.project.number' "$CONFIG_PATH")
BASE_BRANCH=$(jq -r '.base_branch // "main"' "$CONFIG_PATH")
HUMAN_APPROVES=$(jq -r '.human_approves_merge // false' "$CONFIG_PATH")
REBUILD_CAP=$(jq -r '.rebuild_cap // 2' "$CONFIG_PATH")
BLOCK_ALERT_PCT=$(jq -r '.block_rate_alert_pct // 30' "$CONFIG_PATH")
TICK_SECONDS=$(jq -r '.tick_seconds // 120' "$CONFIG_PATH")
MAX_WORKERS=$(jq -r '.max_workers // 3' "$CONFIG_PATH")
BUILD_SLOTS=$(jq -r '.build_slots // 1' "$CONFIG_PATH"); [ "$BUILD_SLOTS" -ge 1 ] 2>/dev/null || BUILD_SLOTS=1
BOT_LOGIN=$(jq -r '.notifications.bot_identity // .bot_identity // ""' "$CONFIG_PATH")
WORKER_BACKEND=$(jq -r '.worker_backend // "workflow"' "$CONFIG_PATH")
# Runaway controls (issue #8). NO_PROGRESS_CYCLES counts dispatch cycles with no
# card reaching Done, regardless of lane occupancy. MAX_DISPATCHES=0 disables the ceiling.
NO_PROGRESS_CYCLES=$(jq -r '.no_progress_cycles // 6' "$CONFIG_PATH")
GROOM_ENABLED=$(jq -r '.groom.enabled // true' "$CONFIG_PATH")
GROOM_BACKEND=$(jq -r '.groom.backend // "claude"' "$CONFIG_PATH")
# Derate the intake lane (groom.ready_floor, default 1): only groom while Ready holds
# at or below this many stories, so a full groom agent does not run every tick — a
# needless token drain that starves review/build of the same quota.
GROOM_READY_FLOOR=$(jq -r '.groom.ready_floor // 1' "$CONFIG_PATH")
# Skip re-grooming the same backlog. Only groom when the Backlog signature changes
# (new stories / a new epic) or the cooldown elapses — so a posted scope decision is
# still picked up, but an identical no-op groom agent no longer runs every tick.
GROOM_COOLDOWN=$(jq -r '.groom.cooldown_seconds // 1800' "$CONFIG_PATH")
GROOM_STATE=".claude/super-board/groom-state.json"
GROOM_SIG=""
LANE_BACKEND=$(jq -r '.lane_backend // "claude"' "$CONFIG_PATH")
PROGRESS_SECONDS=$(jq -r '.progress_seconds // 120' "$CONFIG_PATH")
MAX_DISPATCHES=$(jq -r '.max_dispatches // 0' "$CONFIG_PATH")

# Workflow is the default backend (v1.6.0). This legacy dispatcher only runs
# when the config opts in explicitly — never by accident or stale habit.
if [ "$WORKER_BACKEND" != "claude-p" ]; then
  echo "🛑 board '${CONFIG_SLUG}' uses the workflow backend (worker_backend=${WORKER_BACKEND})." >&2
  echo "    Run it in-session: /super-board run ${CONFIG_SLUG}  (see references/run-workflow.md)" >&2
  echo "    To use this legacy dispatcher, set \"worker_backend\": \"claude-p\" in the config." >&2
  exit 78
fi

RUN_DATE=$(date +%Y-%m-%d)
RUN_MANIFEST="docs/super-board/runs/${RUN_DATE}-${CONFIG_SLUG}.md"
# Per-worker logs (issue #13). Workers used to be spawned with >/dev/null, so the run
# log could never show what a worker was doing during a 13-minute silence.
WORKER_LOG_DIR="docs/super-board/runs/${RUN_DATE}-${CONFIG_SLUG}-workers"
INFLIGHT_DIR=".claude/super-board/inflight"
mkdir -p "docs/super-board/runs" "$WORKER_LOG_DIR" .claude/worktrees "$INFLIGHT_DIR"
fi  # end non-lib-only setup

# Defaults so the helpers below are safe to source under `set -u` in lib-only mode.
: "${RUN_MANIFEST:=/dev/null}"
: "${WORKER_LOG_DIR:=/dev/null}"
: "${INFLIGHT_DIR:=/dev/null}"
: "${PROJECT_OWNER:=}" ; : "${PROJECT_NUMBER:=0}" ; : "${BOT_LOGIN:=}"
# Board checkout root: Review reads policy (skill, run.md, gate) from HERE, never the card
# worktree, so a policy change reaches in-flight cards (2026-10-15 review-loop lesson).
: "${BOARD_ROOT:=$(pwd)}"

# ───────────────────────────── helpers ─────────────────────────────
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$RUN_MANIFEST"; }

PROJECT_ITEMS_JSON=""
fetch_project_items() {
  # One board read per tick; all column lookups read from this cache.
  # super-board-card.sh items: ~1 GraphQL point per 100 cards, where
  # `gh project item-list` spends 101 per 100.
  local fresh
  fresh=$("$(dirname "$SB_GITHUB_READ")/super-board-card.sh" --owner "$PROJECT_OWNER" --number "$PROJECT_NUMBER" items) || return $?
  PROJECT_ITEMS_JSON="$fresh"
}

column_count() {
  echo "$PROJECT_ITEMS_JSON" | jq --arg col "$1" '[.items[] | select(.status == $col)] | length'
}

# ── Status-field resolution (issue #10 reconcile path).
# Option IDs are resolved BY NAME at runtime and cached for the run. Never hard-code
# them: `updateProjectV2Field` replaces the whole option list and remints every ID,
# so a hard-coded map goes stale silently the first time anyone edits the columns.
STATUS_FIELD_ID=""
STATUS_OPTIONS_JSON=""
resolve_status_field() {
  [ -n "$STATUS_FIELD_ID" ] && return 0
  local payload
  payload=$(python3 "$SB_GITHUB_READ" --kind fields -- project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json) || return $?
  STATUS_FIELD_ID=$(echo "$payload" | jq -r '.fields[] | select(.name == "Status") | .id')
  STATUS_OPTIONS_JSON=$(echo "$payload" | jq -c '.fields[] | select(.name == "Status") | .options')
  [ -n "$STATUS_FIELD_ID" ] && [ "$STATUS_FIELD_ID" != "null" ]
}

status_option_id() {
  # $1 = option name. Fails loud (exit 1 + empty output) when the name is absent
  # from the live option set, rather than mutating with a stale ID.
  local id
  id=$(echo "${STATUS_OPTIONS_JSON:-[]}" | jq -r --arg n "$1" '
    map(select(.name == $n)) | .[0].id // empty' 2>/dev/null)
  [ -n "$id" ] || return 1
  echo "$id"
}

set_card_status() {
  # $1 = project item id, $2 = target status name. Returns non-zero if unresolvable.
  local item_id="$1" name="$2" opt_id
  resolve_status_field || { gh_checkpoint; log "⚠ could not resolve Status field — skipping reconcile"; return 1; }
  opt_id=$(status_option_id "$name") || {
    log "⚠ Status option '${name}' not present on the board — skipping reconcile"; return 1; }
  local project_id
  project_id=$(project_node_id) || return $?
  gh_checkpoint
  gh_write_once project item-edit --id "$item_id" --project-id "$project_id" \
    --field-id "$STATUS_FIELD_ID" --single-select-option-id "$opt_id" >/dev/null 2>&1
}

PROJECT_NODE_ID=""
project_node_id() {
  if [ -z "$PROJECT_NODE_ID" ]; then
    local payload
    payload=$(python3 "$SB_GITHUB_READ" --kind project -- project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json) || return $?
    PROJECT_NODE_ID=$(echo "$payload" | jq -r .id)
  fi
  echo "$PROJECT_NODE_ID"
}

issue_is_open() {
  # $1 = issue number. Returns 0 when OPEN, 1 when CLOSED.
  # Unreadable is distinct from both OPEN and CLOSED: exit 79 halts the run.
  local state
  state=$(python3 "$SB_GITHUB_READ" --kind state -- issue view "$1" --json state -q '.state') || return 79
  [ "$state" != "CLOSED" ]
}

TOP_ISSUE=""
TOP_ITEM_ID=""
card_lane() {
  # "qa" when issue $1 carries the `qa` label on the board snapshot, else "build".
  # Labels sit on the item (`labels`) or its content, as names or {name}.
  echo "$PROJECT_ITEMS_JSON" | jq -r --argjson n "$1" '
    [.items[] | select(.content.number == $n)
     | ((.labels // []) + (.content.labels // []))[]
     | (if type == "object" then .name else . end) | ascii_downcase]
    | if index("qa") then "qa" else "build" end' 2>/dev/null || echo build
}

top_card_in_column() {
  # Sets TOP_ISSUE / TOP_ITEM_ID to the FIRST dispatchable card in column $1:
  # no assignee, no local in-flight lock, and the underlying issue still OPEN.
  # A CLOSED issue found in a non-terminal column is reconciled to Done and skipped —
  # dispatching a worker at it is the single largest observed waste category (issue #10).
  #
  # The result is returned via TOP_ISSUE, NOT stdout: this function logs as it
  # reconciles, and log lines on stdout would be captured by a `$(...)` caller and
  # read back as a card number.
  local col="$1" issue item_id
  TOP_ISSUE=""; TOP_ITEM_ID=""
  while IFS=$'\t' read -r issue item_id; do
    [ -n "$issue" ] || continue
    issue_locked "$issue" && continue
    local issue_rc=0
    card_issue_is_open "$issue" || issue_rc=$?
    if [ "$issue_rc" -gt 1 ]; then
      block_card_read "$issue" "${item_id:-}"
      continue
    fi
    if [ "$issue_rc" -ne 0 ]; then
      log "reconciled closed #${issue} -> Done (was '${col}') — dispatching 0 workers for it"
      set_card_status "$item_id" "Done" || { gh_checkpoint; log "  ↳ reconcile of #${issue} could not be written to the board"; return 1; }
      gh_checkpoint
      [ -n "$BOT_LOGIN" ] && gh_write_once issue edit "$issue" --remove-assignee "$BOT_LOGIN" >/dev/null 2>&1 || true
      rm -f "$INFLIGHT_DIR/$issue"
      continue
    fi
    TOP_ISSUE="$issue"; TOP_ITEM_ID="$item_id"
    return 0
  done <<EOF
$(echo "$PROJECT_ITEMS_JSON" | jq -r --arg col "$col" '
    .items[]
    | select(.status == $col and .content.type == "Issue")
    | select((.content.assignees // []) | length == 0)
    | [(.content.number | tostring), (.id // "")] | @tsv')
EOF
  return 1
}

read_lock() {
  # Reads $INFLIGHT_DIR/$1 (bash-assignment format) into PID/LANE/STARTED.
  # Sets empty strings if the file is missing or legacy single-PID format.
  local lock="$INFLIGHT_DIR/$1"
  PID=""; LANE=""; STARTED=""; PROVIDER="claude"
  [ -f "$lock" ] || return 1
  if grep -q '^PID=' "$lock" 2>/dev/null; then
    # shellcheck disable=SC1090
    . "$lock" 2>/dev/null || true
  else
    # Legacy format (pre v1.3.0): single line PID only.
    PID=$(cat "$lock" 2>/dev/null || echo "")
  fi
  return 0
}

issue_locked() {
  # Returns 0 if the issue has a live in-flight lock; cleans stale locks.
  gh_checkpoint
  local issue="$1" lock="$INFLIGHT_DIR/$1"
  [ -f "$lock" ] || return 1
  read_lock "$issue"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    return 0
  fi
  rm -f "$lock"
  return 1
}

lane_idle() {
  local pid="${1:-}"
  [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null
}

gh_rate_guard() {
  # Sleep until rate limit resets if GraphQL remaining < 200.
  local payload remaining reset now wait
  payload=$(python3 "$SB_GITHUB_READ" --kind quota -- api rate_limit) || return $?
  # REST misreports the GraphQL bucket; super-board-gh-guard.sh → sb_gh_quota_merge.
  payload=$(. "$(dirname "$SB_GITHUB_READ")/super-board-gh-guard.sh" && sb_gh_quota_merge "$payload")
  remaining=$(echo "$payload" | jq -r '.resources.graphql.remaining // 5000')
  if [ "$remaining" -lt 200 ]; then
    reset=$(echo "$payload" | jq -r '.resources.graphql.reset // 0')
    now=$(date +%s)
    wait=$((reset - now + 10))
    [ "$wait" -lt 60 ] && wait=60
    log "⚠ GraphQL rate limit low (${remaining} left) — sleeping ${wait}s until reset"
    sleep "$wait"
  fi
}

try_claim_assignee() {
  # Atomic claim. Returns 0 if we won the claim, 1 if someone else beat us.
  # Skipped when bot_identity is unset (solo single-user runs rely on local locks only).
  # We rely on `top_card_in_column` having already filtered out cards with assignees
  # from the cached project item-list — so we attempt the edit directly without a
  # pre-check `gh issue view`. Saves one GraphQL call per dispatch. The edit is
  # idempotent for self-assign; on race-loss, gh returns non-zero and we skip.
  local issue="$1"
  [ -z "$BOT_LOGIN" ] && return 0
  gh_checkpoint
  gh_write_once issue edit "$issue" --add-assignee "$BOT_LOGIN" >/dev/null 2>&1 || {
    log "claim failed on #${issue} (race or gh api error) — skipping this tick"
    return 1
  }
  return 0
}

start_progress_heartbeat() {
  # $1 lane  $2 issue  $3 worker pid  $4 worker log
  # Writes a progress line every PROGRESS_SECONDS (default 120s) with elapsed time and the
  # worker's latest output line, so lanes report progress every 2 minutes instead of only
  # at completion. Self-terminates when the worker exits.
  #
  # Runs as its OWN bash process with a distinct argv[0] ("super-board-heartbeat"). A
  # `( ... ) &` subshell would inherit this runner's argv, and /proc/<pid>/cmdline would
  # then read `bash .claude/bin/super-board-run.sh fieldops` — so `pgrep -f
  # "super-board-run.sh fieldops"` counted the heartbeat as a second runner (watchdog
  # dedupe killed it; restart/orphan logic could misjudge liveness).
  local lane="$1" issue="$2" wpid="$3" wlog="$4"
  local prog="${WORKER_LOG_DIR}/progress-${lane}-${issue}.log"
  SB_HB_WPID="$wpid" SB_HB_LOG="$prog" SB_HB_WLOG="$wlog" \
  SB_HB_LANE="$lane" SB_HB_ISSUE="$issue" SB_HB_SECONDS="${PROGRESS_SECONDS:-120}" \
    nohup bash -c '
      start=$(date +%s)
      while kill -0 "$SB_HB_WPID" 2>/dev/null; do
        sleep "$SB_HB_SECONDS"
        kill -0 "$SB_HB_WPID" 2>/dev/null || break
        now=$(date +%s)
        last=$(grep -v "^[[:space:]]*$" "$SB_HB_WLOG" 2>/dev/null | tail -n 1 | tr -d "\r" | cut -c1-240)
        printf "[%s] lane=%s issue=#%s alive %ss — %s\n" "$(date -u +%FT%TZ)" "$SB_HB_LANE" "$SB_HB_ISSUE" "$((now-start))" "$last" >> "$SB_HB_LOG"
      done
    ' super-board-heartbeat >/dev/null 2>&1 &
}

review_worktree() {
  # Hand the Review lane a clean per-issue worktree so the reviewer's working-tree scope
  # check runs on a pristine tree instead of the host checkout, which accumulates untracked
  # runtime state (halts, pauses, run docs). Prints the worktree path on success; non-zero
  # (caller falls back to the host cwd) when the card's branch is unknown or the worktree
  # cannot be created.
  local issue="$1" wt branch
  wt=".claude/worktrees/issue-${issue}-review"
  if [ -d "$wt" ]; then printf '%s\n' "$wt"; return 0; fi
  branch=$(git for-each-ref --format='%(refname:short)' \
    "refs/heads/issue-${issue}-*" "refs/remotes/origin/issue-${issue}-*" 2>/dev/null | head -n1 || true)
  [ -n "$branch" ] || return 1
  case "$branch" in
    origin/*) branch="${branch#origin/}"; git worktree add --track -b "$branch" "$wt" "origin/$branch" >/dev/null 2>&1 || return 1 ;;
    *)        git worktree add "$wt" "$branch" >/dev/null 2>&1 || return 1 ;;
  esac
  [ -d "$wt" ] || return 1
  printf '%s\n' "$wt"
}

dispatch_lane() {
  # $1 = lane (build|qa|review); $2 = issue number
  local lane="$1" issue="$2" prompt pid provider card_json review_wt=""
  provider=$(lane_provider "$lane") || {
    log "no provider available for lane=${lane} issue=#${issue}"
    # A frozen pipeline must not be invisible: surface it once per 30 min in a
    # small persistent file the orchestrator/status can see, not just the run log.
    att=".claude/super-board/needs-attention.log"
    if [ ! -f "$att" ] || [ $(( $(date +%s) - $(stat -c %Y "$att" 2>/dev/null || echo 0) )) -ge 1800 ]; then
      printf '%s no provider available for lane=%s issue=#%s (check .claude/super-board/provider-pauses/)\n' \
        "$(date -u +%FT%TZ)" "$lane" "$issue" >> "$att"
    fi
    return 1
  }
  if issue_locked "$issue"; then
    log "skip dispatch lane=${lane} issue=#${issue} — already locked"
    return 1
  fi
  # Authoritative closed-issue gate (issue #10). top_card_in_column also filters and
  # reconciles, but every dispatch path funnels through here — one guard, one place.
  gh_checkpoint
  local issue_rc=0
  card_issue_is_open "$issue" || issue_rc=$?
  if [ "$issue_rc" -gt 1 ]; then
    block_card_read "$issue"
    return 1
  fi
  if [ "$issue_rc" -ne 0 ]; then
    log "skip dispatch lane=${lane} issue=#${issue} — issue is CLOSED"
    return 1
  fi
  if ! try_claim_assignee "$issue"; then
    return 1
  fi
  case "$lane" in
    build|build2) prompt="Run super-build on issue #${issue} for super-board run. Read .claude/skills/super-board/references/run.md → Builder lifecycle. Config: ${CONFIG_PATH}." ;;
    qa)     prompt="Run super-qa on issue #${issue} for super-board run. Read .claude/skills/super-board/references/run.md → Tester lifecycle. Config: ${CONFIG_PATH}." ;;
    review) prompt="Run super-review on issue #${issue} for super-board run. This worktree is the CARD BRANCH — read POLICY from the board checkout instead, so a policy change reaches this card: ${BOARD_ROOT}/.claude/skills/super-review/SKILL.md, ${BOARD_ROOT}/.claude/skills/super-board/references/run.md → Reviewer lifecycle, and ${BOARD_ROOT}/.claude/skills/super-board/references/security-gate.md. Run the merge gate as ${BOARD_ROOT}/.claude/bin/super-board-merge-gate.sh --config ${BOARD_ROOT}/.claude/super-board/configs/${CONFIG_SLUG}.json. Review the diff in this worktree; do not read policy from it." ;;
    *) log "unknown lane: $lane"; return 1 ;;
  esac
  # Review runs in its own worktree, never the host checkout (see review_worktree).
  if [ "$lane" = "review" ]; then
    review_wt=$(review_worktree "$issue" || true)
    [ -n "$review_wt" ] && log "review #${issue}: isolated worktree ${review_wt}"
  fi
  # Worker output goes to a per-worker log, not /dev/null (issue #13). Redirect at the
  # `claude` invocation itself — no wrapping subshell, no `exec` — so the wire to the
  # file survives and `$!` names the worker process rather than a bash stub.
  local worker_log="${WORKER_LOG_DIR}/worker-${lane}-${issue}.log"
  {
    printf '=== dispatch lane=%s issue=#%s at %s ===\n' "$lane" "$issue" "$(date -u +%FT%TZ)"
    printf 'prompt: %s\n\n' "$prompt"
  } >> "$worker_log"
  gh_checkpoint
  # Review stays on Claude (board rule); build/qa fall back claude → codex → deepseek
  # → openrouter (usage_order + usage_fallback) so the board keeps moving when the paid
  # plans are exhausted. Fallback hosts never own Review or merge.
  # Review is launched inside its isolated worktree via `env -C <dir>` (which execs straight
  # through, so `$!` still names the worker, not a bash stub). Every other lane keeps the host cwd.
  case "$provider" in
    codex)
      if [ -n "$review_wt" ]; then
        SB_GITHUB_HALT_FILE="$(card_halt_path "$issue")" nohup env -C "$review_wt" codex exec -s danger-full-access "$prompt" >> "$worker_log" 2>&1 &
      else
        SB_GITHUB_HALT_FILE="$(card_halt_path "$issue")" nohup codex exec -s danger-full-access "$prompt" >> "$worker_log" 2>&1 &
      fi
      ;;
    deepseek|openrouter)
      card_json=$(card_json_for "$issue")
      SB_GITHUB_HALT_FILE="$(card_halt_path "$issue")" nohup bash ".claude/bin/super-board-${provider}-lane.sh" --config "$CONFIG_PATH" --lane "$lane" --card "$card_json" >> "$worker_log" 2>&1 &
      ;;
    *)
      if [ -n "$review_wt" ]; then
        SB_GITHUB_HALT_FILE="$(card_halt_path "$issue")" nohup env -C "$review_wt" claude -p "$prompt" --dangerously-skip-permissions >> "$worker_log" 2>&1 &
      else
        SB_GITHUB_HALT_FILE="$(card_halt_path "$issue")" nohup claude -p "$prompt" --dangerously-skip-permissions >> "$worker_log" 2>&1 &
      fi
      ;;
  esac
  pid=$!
  start_progress_heartbeat "$lane" "$issue" "$pid" "$worker_log"
  DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
  DISPATCH_LOG="${DISPATCH_LOG}${issue}
"
  # v1.3.0+ lock format: bash-assignment style so `super-board stop` can source it
  # to recover lane + dispatch time. issue_locked()/reap_finished_locks() still work
  # because PID= is the first line.
  printf 'PID=%s\nLANE=%s\nSTARTED=%s\nPROVIDER=%s\n' "$pid" "$lane" "$(date -u +%FT%TZ)" "$provider" > "$INFLIGHT_DIR/$issue"
  case "$lane" in
    build) BUILD_PID="$pid"; BUILD_ISSUE="$issue" ;;
    build2) BUILD2_PID="$pid"; BUILD2_ISSUE="$issue" ;;
    qa) QA_PID="$pid"; QA_ISSUE="$issue" ;;
    review) REVIEW_PID="$pid"; REVIEW_ISSUE="$issue" ;;
  esac
  log "dispatch lane=${lane} issue=#${issue} pid=${pid} claim=${BOT_LOGIN:-local-only}"
}

dispatch_groom() {
  # Backlog->Ready grooming lane: no card, no assignee claim, no per-issue lock.
  # Falls back claude → codex → deepseek → openrouter like build/qa, so the backlog
  # keeps getting refined (and Ready stays stocked) while the paid plans are exhausted.
  local prompt pid worker_log provider
  provider=$(lane_provider groom) || return 0
  prompt="Run super-groom for super-board run. Read .claude/skills/super-groom/SKILL.md (and .claude/skills/super-board/references/run.md). Config: ${CONFIG_PATH}."
  worker_log="${WORKER_LOG_DIR}/worker-groom.log"
  {
    printf '=== dispatch lane=groom backend=%s at %s ===\n' "$provider" "$(date -u +%FT%TZ)"
    printf 'prompt: %s\n\n' "$prompt"
  } >> "$worker_log"
  gh_checkpoint
  case "$provider" in
    codex)
      nohup codex exec -s danger-full-access "$prompt" >> "$worker_log" 2>&1 & ;;
    deepseek|openrouter)
      nohup bash ".claude/bin/super-board-${provider}-lane.sh" --config "$CONFIG_PATH" --lane groom >> "$worker_log" 2>&1 & ;;
    *)
      nohup claude -p "$prompt" --dangerously-skip-permissions >> "$worker_log" 2>&1 & ;;
  esac
  pid=$!
  GROOM_PID="$pid"; GROOM_PROVIDER="$provider"
  printf '{"sig":"%s","at":%s}\n' "${GROOM_SIG:-}" "$(date +%s)" > "$GROOM_STATE" 2>/dev/null || true
  start_progress_heartbeat groom - "$pid" "$worker_log"
  log "dispatch lane=groom backend=${provider} pid=${pid}"
}

reap_finished_groom() {
  [ -n "${GROOM_PID:-}" ] || return 0
  kill -0 "$GROOM_PID" 2>/dev/null && return 0
  local provider="${GROOM_PROVIDER:-${GROOM_BACKEND:-claude}}"
  if provider_limit_log "$provider" "${WORKER_LOG_DIR}/worker-groom.log"; then
    pause_provider "$provider" "vendor limit in groom worker log"
  fi
  GROOM_PID=""; GROOM_PROVIDER=""
}

issue_status() {
  # Lookup issue #$1 in the cached project items; emit its current column name (or empty).
  echo "$PROJECT_ITEMS_JSON" | jq -r --arg n "$1" '
    .items[] | select(.content.number == ($n | tonumber)) | .status' | head -1
}

card_json_for() {
  # $1 issue -> the card JSON the fallback lane runners expect: {"number":N,"status":col,"title":…}
  local title
  title=$(echo "$PROJECT_ITEMS_JSON" | jq -r --argjson n "$1" '.items[]|select(.content.number==$n)|.content.title' 2>/dev/null | head -1)
  jq -cn --argjson n "$1" --arg st "$(issue_status "$1")" --arg t "${title:-}" '{number:$n,status:$st,title:$t}'
}

check_lane_zombie() {
  # $1 = lane name (build|qa|review); $2 = space-separated list of expected source columns.
  # If the lane's worker PID is alive but its claimed issue has already moved to a column
  # NOT in the expected source set, the worker's logical work is done — kill the zombie
  # process and free the lane. Uses cached project items only (no extra API calls).
  local lane="$1" expected="$2" pid="" issue=""
  case "$lane" in
    build)  pid="$BUILD_PID";  issue="$BUILD_ISSUE" ;;
    build2) pid="$BUILD2_PID"; issue="$BUILD2_ISSUE" ;;
    qa)     pid="$QA_PID";     issue="$QA_ISSUE" ;;
    review) pid="$REVIEW_PID"; issue="$REVIEW_ISSUE" ;;
    *) return 1 ;;
  esac
  [ -z "$pid" ] && return 0
  [ -z "$issue" ] && return 0
  kill -0 "$pid" 2>/dev/null || return 0   # already dead → reap_finished_locks handles it
  local cur found=0 col
  cur=$(issue_status "$issue")
  [ -z "$cur" ] && return 0                # not in cache (closed/deleted/race) → don't kill
  for col in $expected; do
    [ "$cur" = "$col" ] && found=1
  done
  if [ "$found" -eq 0 ]; then
    gh_checkpoint
    log "💀 zombie ${lane} worker on #${issue} (pid=${pid}) — card moved to '${cur}'; killing"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    gh_checkpoint
    [ -n "$BOT_LOGIN" ] && gh_write_once issue edit "$issue" --remove-assignee "$BOT_LOGIN" >/dev/null 2>&1 || true
    gh_checkpoint
    rm -f "$INFLIGHT_DIR/$issue"
    case "$lane" in
      build)  BUILD_PID="";  BUILD_ISSUE="" ;;
      build2) BUILD2_PID=""; BUILD2_ISSUE="" ;;
      qa)     QA_PID="";     QA_ISSUE="" ;;
      review) REVIEW_PID=""; REVIEW_ISSUE="" ;;
    esac
  fi
}

sweep_lane_zombies() {
  check_lane_zombie build  "Ready Building"
  check_lane_zombie build2 "Ready Building"
  check_lane_zombie qa     "QA"
  check_lane_zombie review "Review"
}

done_signature() {
  # The set of cards that have LANDED, as a stable string. This — not lane
  # occupancy — is the run's definition of forward progress (issue #8).
  # A card deliberately dropped is closed and moved to Done too (v3.0.0: no Skipped column).
  echo "$PROJECT_ITEMS_JSON" | jq -r '
    [.items[] | select(.status == "Done") | .content.number // empty]
    | sort | @csv' 2>/dev/null || echo ""
}

record_cycle_progress() {
  # One dispatch cycle's verdict on forward progress (issue #8).
  # Reads/writes PREV_DONE_SIG + NO_PROGRESS_CYCLE_COUNT + LANDED_COUNT.
  # Returns 0 = keep running, 1 = halt (runaway).
  # $1 = the current done signature (injected so tests need no board).
  local cur="$1"
  if [ "$cur" != "$PREV_DONE_SIG" ]; then
    LANDED_COUNT=$((LANDED_COUNT + 1))
    NO_PROGRESS_CYCLE_COUNT=0
    PREV_DONE_SIG="$cur"
    return 0
  fi
  NO_PROGRESS_CYCLE_COUNT=$((NO_PROGRESS_CYCLE_COUNT + 1))
  [ "$NO_PROGRESS_CYCLE_COUNT" -lt "$NO_PROGRESS_CYCLES" ]
}

dispatch_ceiling_hit() {
  # Returns 0 when the hard spend ceiling is reached. MAX_DISPATCHES=0 disables it.
  [ "$MAX_DISPATCHES" -gt 0 ] && [ "$DISPATCH_COUNT" -ge "$MAX_DISPATCHES" ]
}

runaway_summary() {
  # Loud, actionable halt line: what the run spent, and on what.
  log "   dispatches=${DISPATCH_COUNT} reaps=${REAP_COUNT} cards-landed-this-run=${LANDED_COUNT}"
  local top
  top=$(printf '%s' "$DISPATCH_LOG" | grep -c . 2>/dev/null || echo 0)
  if [ "${top:-0}" -gt 0 ]; then
    log "   most re-dispatched issues (count issue):"
    printf '%s' "$DISPATCH_LOG" | grep . | sort | uniq -c | sort -rn | head -5 | while read -r line; do
      log "     $line"
    done
  fi
  log "   → inspect worker logs in ${WORKER_LOG_DIR}/"
}

reap_finished_locks() {
  # Sweep inflight/ for dead PIDs; remove locks AND sweep stale assignees so the
  # next dispatch can re-claim the card if the worker crashed without releasing.
  # The assignee remove is idempotent — no-op if the worker exited cleanly.
  local lock issue
  for lock in "$INFLIGHT_DIR"/*; do
    gh_checkpoint
    [ -f "$lock" ] || continue
    issue=$(basename "$lock")
    # Issue locks only: basenames are issue numbers. Anything else (e.g. the
    # workflow backend's workflow-wave.lock) is not ours to reap — deleting it
    # would dissolve the backend mutual exclusion mid-run.
    case "$issue" in *[!0-9]*|'') continue ;; esac
    read_lock "$issue"
    if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
      if [ -f "$(card_halt_path "$issue")" ]; then
        block_card_read "$issue"
        REAP_COUNT=$((REAP_COUNT + 1))
        continue
      fi
      local worker_log="${WORKER_LOG_DIR}/worker-${LANE}-${issue}.log"
      if provider_limit_log "$PROVIDER" "$worker_log"; then
        pause_provider "$PROVIDER" "vendor limit in worker log"
      fi
      gh_checkpoint
      if [ -n "$BOT_LOGIN" ]; then
        gh_checkpoint
        gh_write_once issue edit "$issue" --remove-assignee "$BOT_LOGIN" >/dev/null 2>&1 || true
        log "reaped stale lock + swept assignee on #${issue} (pid=${PID:-empty})"
      else
        log "reaped stale lock for #${issue} (pid=${PID:-empty})"
      fi
      gh_checkpoint
      rm -f "$lock"
      REAP_COUNT=$((REAP_COUNT + 1))
    fi
  done
}

check_legacy_worktrees() {
  # Never strand a previous run's edits by silently switching its folder.
  local wt
  for wt in .worktrees/issue-*; do
    [ -e "$wt" ] || continue
    log "🛑 legacy worktree $wt exists — stop its worker and inspect/preserve its edits"
    log "    Move it with git worktree move to .claude/worktrees/ before resuming."
    return 73
  done
  return 0
}

cleanup_stale_worktrees() {
  # This directory also holds Claude's unrelated worktrees. Only board names
  # belong to this sweep, and a failed Git removal must never become rm -rf.
  local wt branch
  for wt in .claude/worktrees/issue-*; do
    [ -d "$wt" ] || continue
    [[ "${wt##*/}" =~ ^issue-[0-9]+(-(build|qa|review))?$ ]] || continue
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    # Detached work may contain commits with no other ref; it is not proof of staleness.
    [ -n "$branch" ] || continue
    if ! git rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
      if git worktree remove "$wt" 2>/dev/null; then
        log "stale worktree: $wt (branch '$branch' missing) — removed"
      else
        log "⚠ kept worktree $wt — inspect its edits/lock before cleanup"
      fi
    fi
  done
  return 0
}

declare -A STRANDED_TICKS=()
reclaim_stranded_building() {
  local issue item_id count target state_dir
  state_dir="$(dirname "$SB_GLOBAL_HALT_FILE")/recovered"
  while IFS=$'\t' read -r issue item_id; do
    [ -n "$issue" ] || continue
    if issue_locked "$issue"; then STRANDED_TICKS[$issue]=0; continue; fi
    count=$(( ${STRANDED_TICKS[$issue]:-0} + 1 ))
    STRANDED_TICKS[$issue]=$count
    [ "$count" -ge 2 ] || continue
    target=Ready
    [ ! -f "$state_dir/$issue" ] || target=Blocked
    if set_card_status "$item_id" "$target"; then
      mkdir -p "$state_dir"; touch "$state_dir/$issue"
      STRANDED_TICKS[$issue]=0
      PROJECT_ITEMS_JSON=$(echo "$PROJECT_ITEMS_JSON" | jq --argjson n "$issue" --arg status "$target" '(.items[] | select(.content.number == $n) | .status) = $status')
      [ -z "$BOT_LOGIN" ] || gh_write_once issue edit "$issue" --remove-assignee "$BOT_LOGIN" >/dev/null
      gh_write_once issue comment "$issue" --body "[orchestrator] [report] stranded Building card recovered
Did: observed two idle ticks without a live worker
✅ Done: moved to $target; preserved branches and worktree edits
blocked-by: ${target/Ready/none}" >/dev/null
      log "recovered stranded #${issue} to ${target}; worktree preserved"
    fi
  done <<EOF
$(echo "$PROJECT_ITEMS_JSON" | jq -r --arg bot "$BOT_LOGIN" '.items[] | select(.status == "Building" and .content.type == "Issue") | select(((.content.assignees // []) - [$bot]) | length == 0) | [(.content.number | tostring), .id] | @tsv')
EOF
  # A tick outside Building breaks the consecutive-idle sequence.
  for issue in "${!STRANDED_TICKS[@]}"; do
    [ "$(issue_status "$issue")" = Building ] || unset 'STRANDED_TICKS[$issue]'
  done
}

sweep_blocked_by() {
  # Free a card parked with `blocked-by: <n>` once EVERY referenced issue is closed.
  # The workflow backend sweeps this at wave start; the claude-p runner must too, or a
  # merged blocker strands the next card indefinitely (2026-10-15: #229 sat Blocked behind
  # a merged #228 and the board went idle). One `gh issue view` per Blocked card, per sweep.
  local issue item_id last blocked num st rc all
  while IFS=$'\t' read -r issue item_id; do
    [ -n "$issue" ] || continue
    if issue_locked "$issue"; then continue; fi
    last=$(gh issue view "$issue" --json comments -q '.comments[-1].body // ""' 2>/dev/null) || continue
    blocked=$(printf '%s\n' "$last" | sed -n 's/^blocked-by:[[:space:]]*//p' | tail -1)
    [ -n "$blocked" ] || continue
    case "$blocked" in -*|'') continue ;; esac     # `-`/empty = blocked for a reason, not sequencing
    all=1
    for num in $(printf '%s' "$blocked" | grep -oE '[0-9]+'); do
      st=$(echo "$PROJECT_ITEMS_JSON" | jq -r --argjson n "$num" '.items[]|select(.content.number==$n)|.status' 2>/dev/null | head -1)
      if [ "$st" = "Done" ]; then continue; fi      # blocker already landed on the board
      if issue_is_open "$num"; then rc=0; else rc=$?; fi
      case "$rc" in 1) ;; 0) all=0 ;; *) return 1 ;; esac   # 1 = CLOSED → resolved
    done
    [ "$all" -eq 1 ] || continue
    if set_card_status "$item_id" Ready; then
      PROJECT_ITEMS_JSON=$(echo "$PROJECT_ITEMS_JSON" | jq --argjson n "$issue" '(.items[]|select(.content.number==$n)|.status)="Ready"')
      gh_write_once issue comment "$issue" --body "[orchestrator] [report] unblocked
Did: every blocked-by issue is closed
✅ Done: moved Blocked → Ready to build
blocked-by: none" >/dev/null
      log "unblocked #${issue}: blockers closed → Ready"
    fi
  done <<EOF
$(echo "$PROJECT_ITEMS_JSON" | jq -r '.items[] | select(.status == "Blocked" and .content.type == "Issue") | [(.content.number|tostring), .id] | @tsv')
EOF
}

provider_limit_log() {
  local provider="$1" file="$2" pattern
  [ -f "$file" ] || return 1
  case "$provider" in claude) pattern='session limit' ;; codex) pattern='usage limit|chatgpt\.com' ;; *) return 1 ;; esac
  tail -n 5 "$file" | grep -qiE "$pattern"
}
pause_provider() {
  local pause_dir source="${3:-vendor}" existing_source
  pause_dir="${SB_PROVIDER_PAUSE_DIR:-$(dirname "$SB_GLOBAL_HALT_FILE")/provider-pauses}"
  mkdir -p "$pause_dir"
  existing_source=$(jq -r '.source // "vendor"' "$pause_dir/$1" 2>/dev/null || echo vendor)
  # Keep the first terminal limit's time; repeated log scans must not move it.
  if [ -f "$pause_dir/$1" ] && [ "$existing_source" = vendor ]; then return 0; fi
  jq -n --arg reason "$2" --arg source "$source" '{at:(now | floor),source:$source,reason:$reason}' > "$pause_dir/$1"
  log "paused $1 lanes: $2 (read-only; the runner owns backend selection)"
}
provider_usage_check() {
  # Provider-appropriate usage/balance check. Same JSON contract + exit codes as
  # super-board-usage.sh (0 ok, 10 pause, 3 unknown, 64 usage error).
  local bin; bin="$(dirname "$SB_GITHUB_READ")"
  case "$1" in
    claude|codex) bash "$bin/super-board-usage.sh" check --provider "$1" --config "$CONFIG_PATH" ;;
    deepseek)     bash "$bin/super-board-deepseek-balance.sh" check --config "$CONFIG_PATH" ;;
    openrouter)   bash "$bin/super-board-openrouter-balance.sh" check --config "$CONFIG_PATH" ;;
    *) echo '{"state":"unknown","reason":"unknown provider"}'; return 3 ;;
  esac
}
usage_providers() {
  # Ordered providers for non-review lanes: primary order, then fallbacks. The
  # fallback list is what the deepseek/openrouter lane runners require to accept a call.
  # A missing/unreadable config yields empty jq output (exit 0), so default explicitly.
  local out
  out=$(jq -r '((.usage_order // ["claude","codex"]) + (.usage_fallback // [])) | unique_by(.) | .[]' "$CONFIG_PATH" 2>/dev/null) || true
  [ -n "$out" ] || out=$'claude\ncodex'
  printf '%s\n' "$out"
}
groom_providers() {
  # Providers allowed to groom. Kept separate from build/qa so grooming never spends
  # Claude's or Codex's budget — those are reserved for build/qa (config groom.providers).
  local out
  out=$(jq -r '(.groom.providers // ["deepseek","openrouter"]) | .[]' "$CONFIG_PATH" 2>/dev/null) || true
  [ -n "$out" ] || out=$'deepseek\nopenrouter'
  printf '%s\n' "$out"
}
review_providers() {
  # Providers allowed to review. Claude is preferred (its purpose-built /security-review);
  # Codex is the allowed fallback (config review.providers), where S1 runs as a Codex
  # security pass. Fallback legs (deepseek/openrouter) never review.
  local out
  out=$(jq -r '(.review.providers // ["claude","codex"]) | .[]' "$CONFIG_PATH" 2>/dev/null) || true
  [ -n "$out" ] || out=$'claude\ncodex'
  printf '%s\n' "$out"
}
lane_provider() {
  # First provider allowed for this lane. provider_dispatch_allowed logs to stdout;
  # route that to stderr so the captures below yield only the provider name.
  #   review   → review.providers (claude → codex).
  #   groom    → groom.providers (deepseek → openrouter).
  #   build/qa → usage_order + usage_fallback (claude → codex → deepseek → openrouter).
  local p
  case "$1" in
    review)
      for p in $(review_providers); do provider_dispatch_allowed "$p" >&2 && { echo "$p"; return 0; }; done
      return 1 ;;
    groom)
      for p in $(groom_providers); do provider_dispatch_allowed "$p" >&2 && { echo "$p"; return 0; }; done
      return 1 ;;
  esac
  for p in $(usage_providers); do
    provider_dispatch_allowed "$p" >&2 && { echo "$p"; return 0; }
  done
  return 1
}
provider_dispatch_allowed() {
  local provider="$1" result rc=0 state pause_dir pause_at recorded_at source
  pause_dir="${SB_PROVIDER_PAUSE_DIR:-$(dirname "$SB_GLOBAL_HALT_FILE")/provider-pauses}"
  # A vendor pause records a rate-limit window (~5h). Once that window has elapsed the pause
  # is stale — clear it, since these providers have no usage snapshot to disconfirm it. A
  # stale pause otherwise parks a fully-available provider until a manual reset (2026-10-14).
  if [ -f "$pause_dir/$provider" ]; then
    pause_at=$(jq -r '.at // 0' "$pause_dir/$provider" 2>/dev/null || echo 0)
    local pause_age
    pause_age=$(( $(date +%s) - ${pause_at:-0} ))
    if [ "${pause_at:-0}" -gt 0 ] && [ "$pause_age" -ge "${SB_PAUSE_TTL:-1800}" ]; then
      log "cleared stale $provider pause (age ${pause_age}s ≥ ${SB_PAUSE_TTL:-1800}s window)"
      rm -f "$pause_dir/$provider"
    fi
  fi
  result=$(provider_usage_check "$provider") || rc=$?
  state=$(printf '%s' "$result" | jq -r '.state // "unknown"' 2>/dev/null || echo unknown)
  if [ "$state" = pause ]; then pause_provider "$provider" "$(printf '%s' "$result" | jq -r .reason)" snapshot; return 1; fi
  if [ "$state" = ok ] && [ -f "$pause_dir/$provider" ]; then
    source=$(jq -r '.source // "vendor"' "$pause_dir/$provider" 2>/dev/null || echo vendor)
    pause_at=$(jq -r '.at // 0' "$pause_dir/$provider" 2>/dev/null || echo 0)
    recorded_at=$(printf '%s' "$result" | jq -r '.recorded_at // 0')
    # A low snapshot predating a terminal failure cannot disprove exhaustion.
    if [ "$source" = snapshot ] || [ "$recorded_at" -gt "$pause_at" ]; then
      rm -f "$pause_dir/$provider"
    fi
  fi
  if [ -f "$pause_dir/$provider" ]; then
    log "lane paused: $provider ($(cat "$pause_dir/$provider"))"
    # Claude-first, then Codex: when Claude is the active backend and is exhausted, switch to
    # Codex in place so build/qa keep moving (no runner restart). Review stays Claude and waits.
    if [ "$provider" = "claude" ] && [ "${LANE_BACKEND:-claude}" = "claude" ] && [ ! -f "$pause_dir/codex" ]; then
      LANE_BACKEND="codex"
      python3 - "$CONFIG_PATH" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
try:
    d = json.loads(p.read_text())
except (OSError, ValueError):
    sys.exit(0)
d['lane_backend'] = 'codex'; p.write_text(json.dumps(d, indent=2) + "\n")
PY
      log "backend switched to codex (Claude exhausted) — build/qa continue on Codex; review waits for Claude"
      # Backend changes apply to the next dispatch. This caller still selected
      # exhausted Claude (especially Review), so it must stop here.
      return 1
    fi
    return 1
  fi
  [ "$state" != unknown ] || log "usage $provider unknown (no fresh plan snapshot); dispatch permitted"
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]
}

# ───────────────────────── run counters (shared state) ─────────────────────────
DISPATCH_COUNT=0
REAP_COUNT=0
LANDED_COUNT=0
DISPATCH_LOG=""

# Sourced by the gate tests (`SB_LIB_ONLY=1 . scripts/super-board-run.sh`) to exercise
# the helpers above without starting a run. Executing the script normally is unaffected.
if [ "${SB_LIB_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# A read failure stops only workers launched by this dispatcher. Keep their
# locks, worktrees, claims, and approval evidence for explicit recovery.
halt_cleanup() {
  if ! python3 "$SB_GITHUB_READ" --check >/dev/null 2>&1; then
    for pid in "${BUILD_PID:-}" "${BUILD2_PID:-}" "${QA_PID:-}" "${REVIEW_PID:-}"; do
      [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    done
  fi
}
trap halt_cleanup EXIT
gh_checkpoint

# ───────────────────────────── preconditions ─────────────────────────────
log "super-board run started — config=${CONFIG_SLUG} base=${BASE_BRANCH} tick=${TICK_SECONDS}s max_workers=${MAX_WORKERS} no_progress_cycles=${NO_PROGRESS_CYCLES} max_dispatches=${MAX_DISPATCHES}"

# Orphan-worker guard. `|| true` defends against pipefail when pgrep finds nothing.
ORPHANS=$(pgrep -f 'claude -p .*super-board run' 2>/dev/null | grep -v "^$$\$" | wc -l | tr -d ' ' || true)
ORPHANS=${ORPHANS:-0}
if [ "$ORPHANS" -gt 0 ]; then
  log "🛑 refusing to start: ${ORPHANS} super-board claude workers already running."
  log "    Stop them first: pkill -f 'claude -p .*super-board run'"
  log "    Then re-run: $0 $CONFIG_SLUG"
  exit 73
fi

# Workflow-backend mutual exclusion (see references/run-workflow.md §Preconditions).
WAVE_LOCK=".claude/super-board/inflight/workflow-wave.lock"
if [ -f "$WAVE_LOCK" ]; then
  log "🛑 refusing to start: workflow-backend wave in flight ($WAVE_LOCK exists)."
  log "    If no wave is actually running, remove the stale lock: rm $WAVE_LOCK"
  exit 74
fi

# Production-merge guard.
if [ "$BASE_BRANCH" = "main" ] && [ "$HUMAN_APPROVES" = "false" ]; then
  if rg -qU 'on:\s*\n?\s*push:\s*\n?\s*branches:[^a-z]*main' .github/workflows 2>/dev/null \
     || [ -f vercel.json ] || [ -f netlify.toml ]; then
    log "🛡 refusing to start: would auto-merge to production main."
    exit 75
  fi
fi

# Existing legacy work is inspected/moved by a human, never deleted on upgrade.
check_legacy_worktrees
cleanup_stale_worktrees

# Reap any leftover stale locks from a previous crashed run.
reap_finished_locks

# ───────────────────────────── main loop ─────────────────────────────
gh_rate_guard
fetch_project_items
reclaim_stranded_building; fetch_project_items
INITIAL_READY=$(column_count "Ready")
log "initial Ready count: $INITIAL_READY"

# Landed-work baseline (issue #8). Progress is a change in this set, not lane state.
PREV_DONE_SIG=$(done_signature)
INITIAL_DONE_SIG="$PREV_DONE_SIG"
NO_PROGRESS_CYCLE_COUNT=0
BUILD_PID=""; BUILD_ISSUE=""
BUILD2_PID=""; BUILD2_ISSUE=""
QA_PID=""; QA_ISSUE=""
REVIEW_PID=""; REVIEW_ISSUE=""
GROOM_PID=""; GROOM_PROVIDER=""

while true; do
  gh_checkpoint
  # Workflow-backend mutual exclusion, re-checked every tick: the startup
  # check alone leaves a TOCTOU window where a workflow run starting at the
  # same moment as this dispatcher is never detected by either side.
  if [ -f "$WAVE_LOCK" ]; then
    log "🛑 workflow-backend wave appeared mid-run ($WAVE_LOCK) — halting for mutual exclusion."
    log "    Resume after the wave: $0 $CONFIG_SLUG"
    exit 74
  fi

  reap_finished_locks  # cheap local sweep; runs every tick

  # ── Zombie sweep against the LAST cached project state (no extra API).
  #    Catches workers whose card already moved out of the lane's source column
  #    but whose claude -p process didn't exit. Runs every tick, even cheap ones,
  #    so a cap-reached pipeline can still self-heal when one lane is a zombie.
  sweep_lane_zombies

  # ── Free pre-check: count active lanes from local PIDs (no API calls).
  BUILD_IDLE=1; BUILD2_IDLE=1; QA_IDLE=1; REVIEW_IDLE=1
  lane_idle "$BUILD_PID" || BUILD_IDLE=0
  lane_idle "$BUILD2_PID" || BUILD2_IDLE=0
  lane_idle "$QA_PID" || QA_IDLE=0
  lane_idle "$REVIEW_PID" || REVIEW_IDLE=0

  ACTIVE_WORKERS=0
  [ "$BUILD_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  [ "$BUILD2_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  [ "$QA_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  [ "$REVIEW_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))

  # ── Cheap-tick path: workers at cap → skip GraphQL fetch entirely.
  #    The board can't change in a way that helps us until a lane frees up.
  if [ "$ACTIVE_WORKERS" -ge "$MAX_WORKERS" ]; then
    log "tick — cap reached (${ACTIVE_WORKERS}/${MAX_WORKERS} busy) — skipping GraphQL fetch, sleeping ${TICK_SECONDS}s"
    sleep "$TICK_SECONDS"
    continue
  fi

  # ── Expensive-tick path: we have capacity, fetch real state.
  gh_rate_guard
  fetch_project_items

  reap_finished_locks   # every tick: a restart-stranded QA/Review card recovers without a manual unlock
  reclaim_stranded_building
  sweep_blocked_by   # free cards whose blocked-by issues have since closed

  # Re-sweep zombies against fresh cache; the previous sweep used stale data.
  sweep_lane_zombies
  BUILD_IDLE=1; BUILD2_IDLE=1; QA_IDLE=1; REVIEW_IDLE=1
  lane_idle "$BUILD_PID" || BUILD_IDLE=0
  lane_idle "$BUILD2_PID" || BUILD2_IDLE=0
  lane_idle "$QA_PID" || QA_IDLE=0
  lane_idle "$REVIEW_PID" || REVIEW_IDLE=0
  ACTIVE_WORKERS=0
  [ "$BUILD_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  [ "$BUILD2_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  [ "$QA_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  [ "$REVIEW_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))

  READY=$(column_count "Ready")
  BUILDING=0
  BUILDING=$(column_count "Building")
  QA=$(column_count "QA")
  REVIEW=$(column_count "Review")
  BLOCKED=$(column_count "Blocked")
  BACKLOG=$(column_count "Backlog")

  GROOM_IDLE=1
  reap_finished_groom
  [ -z "${GROOM_PID:-}" ] || GROOM_IDLE=0

  log "tick — Ready=$READY Building=$BUILDING QA=$QA Review=$REVIEW Blocked=$BLOCKED Backlog=$BACKLOG lanes: b_idle=$BUILD_IDLE(#${BUILD_ISSUE:-_}) b2_idle=$BUILD2_IDLE(#${BUILD2_ISSUE:-_}) q_idle=$QA_IDLE(#${QA_ISSUE:-_}) r_idle=$REVIEW_IDLE(#${REVIEW_ISSUE:-_}) g_idle=$GROOM_IDLE"

  # Intake lane: refine Backlog → Ready (super-groom on the groom providers) until the
  # Backlog is drained. Deliberately NOT gated on the build pipeline being empty, so the
  # backlog gets groomed while build/qa keep running; the groom never spends Claude's or
  # Codex's budget. Derated: one groomer at a time, and only while Ready is at or below
  # ${GROOM_READY_FLOOR} (groom.ready_floor) — an agent run every tick needlessly drains
  # the very quota review/build need.
  if [ "${GROOM_ENABLED:-true}" = "true" ] && [ "$BACKLOG" -gt 0 ] && [ "$GROOM_IDLE" -eq 1 ] \
     && [ "${READY:-0}" -le "${GROOM_READY_FLOOR:-1}" ]; then
    GROOM_SIG=$(echo "$PROJECT_ITEMS_JSON" | jq -r '[.items[] | select(.status == "Backlog") | .content.number] | "\(length):\(if length > 0 then max else 0 end)"')
    GROOM_LAST_SIG=$(jq -r '.sig // ""' "$GROOM_STATE" 2>/dev/null || echo "")
    GROOM_LAST_AT=$(jq -r '.at // 0' "$GROOM_STATE" 2>/dev/null || echo 0)
    if [ "$GROOM_SIG" != "$GROOM_LAST_SIG" ] || [ $(( $(date +%s) - ${GROOM_LAST_AT:-0} )) -ge "${GROOM_COOLDOWN:-1800}" ]; then
      dispatch_groom
    else
      log "groom skipped — backlog unchanged (${GROOM_SIG}); forced groom in ≤${GROOM_COOLDOWN}s"
    fi
  fi

  if [ "$READY" -eq 0 ] && [ "$BUILDING" -eq 0 ] && [ "$QA" -eq 0 ] && [ "$REVIEW" -eq 0 ] \
     && [ "${BACKLOG:-0}" -eq 0 ] && [ "$GROOM_IDLE" -eq 1 ] \
     && [ "$BUILD_IDLE" -eq 1 ] && [ "$BUILD2_IDLE" -eq 1 ] && [ "$QA_IDLE" -eq 1 ] && [ "$REVIEW_IDLE" -eq 1 ]; then
    log "✅ all columns empty (incl. Backlog) and all lanes idle — exiting cleanly"
    break
  fi

  if [ "${BLOCK_ALERT_SENT:-0}" -eq 0 ] && [ "$INITIAL_READY" -gt 0 ] && [ "$BLOCK_ALERT_PCT" -gt 0 ]; then
    PCT=$(( BLOCKED * 100 / INITIAL_READY ))
    if [ "$PCT" -ge "$BLOCK_ALERT_PCT" ]; then
      log "⚠ block-rate alert: ${BLOCKED}/${INITIAL_READY} (${PCT}%)"
      BLOCK_ALERT_SENT=1
    fi
  fi

  # ACTIVE_WORKERS already computed at top of loop (free pre-check).
  can_dispatch() {
    [ "$ACTIVE_WORKERS" -lt "$MAX_WORKERS" ]
  }

  if can_dispatch && [ "$REVIEW" -gt 0 ] && [ "$REVIEW_IDLE" -eq 1 ]; then
    if top_card_in_column "Review"; then
      # Reviewer merges on evidence (QA green + review findings clean + security S1+S2 clean +
      # truth at threshold). No governance handoff (retired 2026-10-14).
      if dispatch_lane review "$TOP_ISSUE"; then ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1)); fi
    fi
  fi
  QA_FREE=$QA_IDLE
  if can_dispatch && [ "$QA" -gt 0 ] && [ "$QA_IDLE" -eq 1 ]; then
    if top_card_in_column "QA"; then
      if dispatch_lane qa "$TOP_ISSUE"; then ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1)); QA_FREE=0; fi
    fi
  fi
  # Ready: the top card's label picks the lane — `qa` skips Building (Tester),
  # anything else is built first. A busy lane waits for the next tick.
  if can_dispatch && [ "$READY" -gt 0 ] && { [ "$BUILD_IDLE" -eq 1 ] || [ "$BUILD2_IDLE" -eq 1 ] || [ "$QA_FREE" -eq 1 ]; }; then
    if top_card_in_column "Ready"; then
      if [ "$(card_lane "$TOP_ISSUE")" = "qa" ]; then
        if [ "$QA_FREE" -eq 1 ] && dispatch_lane qa "$TOP_ISSUE"; then ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1)); fi
      elif [ "$BUILD_IDLE" -eq 1 ]; then
        if dispatch_lane build "$TOP_ISSUE"; then ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1)); fi
      elif [ "${BUILD_SLOTS:-1}" -ge 2 ] && [ "$BUILD2_IDLE" -eq 1 ]; then
        if dispatch_lane build2 "$TOP_ISSUE"; then ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1)); fi
      fi
    fi
  fi

  gh_checkpoint

  # ── Landed-work halt gate (issue #8).
  #    Progress = the Done/Skipped set changed since the last dispatch cycle. Lane
  #    occupancy is deliberately NOT part of this condition: the runaway this gate
  #    exists to catch is a pipeline that is 100% busy and lands nothing, and the old
  #    `AND no lane active` clause made that case unhaltable (293 ticks, 0 merges).
  if { [ "$DISPATCH_COUNT" -gt "${PREV_DISPATCH_COUNT:-0}" ] || [ "$ACTIVE_WORKERS" -gt 0 ]; } && ! record_cycle_progress "$(done_signature)"; then
    log "🛑 halt — RUNAWAY: no card reached Done in ${NO_PROGRESS_CYCLES} dispatch cycles"
    runaway_summary
    break
  fi

  # ── Hard dispatch ceiling. Bounds worst-case spend even if the board keeps
  #    trickling just enough Done movement to reset the gate above.
  if dispatch_ceiling_hit; then
    log "🛑 halt — dispatch ceiling reached (${DISPATCH_COUNT}/${MAX_DISPATCHES})"
    runaway_summary
    break
  fi

  PREV_DISPATCH_COUNT=$DISPATCH_COUNT
  sleep "$TICK_SECONDS"
done

log "super-board run finished. manifest: $RUN_MANIFEST"
