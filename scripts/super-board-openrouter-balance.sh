#!/usr/bin/env bash
# super-board-openrouter-balance.sh — OpenRouter credit guard for the run loop.
#
# Mirrors super-board-usage.sh's check contract so the wave loop can treat an
# OpenRouter fallback leg the same way it treats the Claude usage guard, but
# gated on remaining dollar credit instead of a usage-window percentage —
# OpenRouter has no plan window, just a balance that only goes down.
#
# The /credits endpoint needs an OpenRouter Management key (a normal
# inference key gets 403) — set OPENROUTER_MANAGEMENT_KEY separately from
# OPENROUTER_API_KEY (used for the actual chat completions in the lane script).
#
# Usage:
#   super-board-openrouter-balance.sh check [--config <cfg.json>] [--floor N]
#
# Prints one JSON line:
#   {"state":"ok|pause|unknown","remaining":3.42,"floor":1,"reason":"…"}
# Exit: 0 ok, 10 pause (at/under floor — stop dispatching to this lane),
# 3 unknown (no key / API unreachable), 64 usage error.
set -euo pipefail

MODE="${1:-}"; [ $# -gt 0 ] && shift
[ "$MODE" = "check" ] || { echo "usage: super-board-openrouter-balance.sh check [--config f] [--floor N]" >&2; exit 64; }

FLOOR=""; CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --floor)  FLOOR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
if [ -z "$FLOOR" ] && [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
  FLOOR=$(jq -r '.openrouter.floor_credits // empty' "$CONFIG")
fi
FLOOR="${FLOOR:-1}"

if [ -z "${OPENROUTER_MANAGEMENT_KEY:-}" ]; then
  echo '{"state":"unknown","remaining":null,"floor":'"$FLOOR"',"reason":"OPENROUTER_MANAGEMENT_KEY not set (the /credits endpoint needs a management key, not the inference key)"}'
  exit 3
fi

RESPONSE=$(curl -fsS --max-time 10 \
  -H "Authorization: Bearer $OPENROUTER_MANAGEMENT_KEY" \
  https://openrouter.ai/api/v1/credits 2>/dev/null) || {
  echo '{"state":"unknown","remaining":null,"floor":'"$FLOOR"',"reason":"OpenRouter /credits unreachable"}'
  exit 3
}

OUT=$(printf '%s' "$RESPONSE" | jq -c --argjson floor "$FLOOR" '
  (.data.total_credits - .data.total_usage) as $remaining
  | if $remaining == null then
      {state:"unknown", remaining:null, floor:$floor, reason:"unexpected /credits response shape"}
    elif $remaining <= $floor then
      {state:"pause", remaining:$remaining, floor:$floor,
       reason:"\($remaining) credits left, at or under floor \($floor)"}
    else
      {state:"ok", remaining:$remaining, floor:$floor,
       reason:"\($remaining) credits remaining"}
    end' 2>/dev/null) || {
  echo '{"state":"unknown","remaining":null,"floor":'"$FLOOR"',"reason":"could not parse /credits response"}'
  exit 3; }

echo "$OUT"
case "$(echo "$OUT" | jq -r .state)" in
  ok) exit 0 ;;
  pause) exit 10 ;;
  *) exit 3 ;;
esac
