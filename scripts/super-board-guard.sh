#!/usr/bin/env bash
# Optional observer: pause providers on vendor-specific terminal limits.
# It never changes configuration, kills workers, or restarts a runner.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SB_REPO_PATH:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
SB_LIB_ONLY=1 source "$SCRIPT_DIR/super-board-run.sh"
GUARD_START=$(date +%s)
while true; do
  sleep "${SB_GUARD_SECONDS:-60}"
  for lock in .claude/super-board/inflight/[0-9]*; do
    [ -f "$lock" ] || continue
    issue="${lock##*/}"
    [[ "$issue" =~ ^[0-9]+$ ]] || continue
    INFLIGHT_DIR=.claude/super-board/inflight
    read_lock "$issue"
    file=$(find docs/super-board/runs -name "worker-${LANE}-${issue}.log" -newermt "@$GUARD_START" -print -quit 2>/dev/null || true)
    [ -n "$file" ] || continue
    if provider_limit_log "$PROVIDER" "$file"; then
      pause_provider "$PROVIDER" "vendor limit in worker log"
    fi
  done
done
