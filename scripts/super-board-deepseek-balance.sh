#!/usr/bin/env bash
# super-board-deepseek-balance.sh — DeepSeek account-balance guard for the run loop.
#
# Same check contract as super-board-usage.sh / super-board-openrouter-balance.sh,
# gated on DeepSeek's own direct $ balance (api.deepseek.com/user/balance) — a
# separate account/key from OpenRouter, not the same pool.
#
# Usage:
#   super-board-deepseek-balance.sh check [--config <cfg.json>] [--floor N]
#
# Needs DEEPSEEK_API_KEY in the environment.
#
# Prints one JSON line:
#   {"state":"ok|pause|unknown","remaining":2.10,"floor":1,"reason":"…"}
# Exit: 0 ok, 10 pause (at/under floor), 3 unknown (no key / API unreachable
# / no USD balance record), 64 usage error.
set -euo pipefail

MODE="${1:-}"; [ $# -gt 0 ] && shift
[ "$MODE" = "check" ] || { echo "usage: super-board-deepseek-balance.sh check [--config f] [--floor N]" >&2; exit 64; }

FLOOR=""; CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --floor)  FLOOR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
if [ -z "$FLOOR" ] && [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
  FLOOR=$(jq -r '.deepseek.floor_dollars // empty' "$CONFIG")
fi
FLOOR="${FLOOR:-1}"

if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  echo '{"state":"unknown","remaining":null,"floor":'"$FLOOR"',"reason":"DEEPSEEK_API_KEY not set"}'
  exit 3
fi

RESPONSE=$(curl -fsS --max-time 10 \
  -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
  https://api.deepseek.com/user/balance 2>/dev/null) || {
  echo '{"state":"unknown","remaining":null,"floor":'"$FLOOR"',"reason":"DeepSeek /user/balance unreachable"}'
  exit 3
}

OUT=$(printf '%s' "$RESPONSE" | jq -c --argjson floor "$FLOOR" '
  (.balance_infos // [] | map(select(.currency == "USD")) | first.total_balance) as $remaining
  | if $remaining == null then
      {state:"unknown", remaining:null, floor:$floor, reason:"no USD balance in /user/balance response"}
    elif ($remaining | tonumber) <= $floor then
      {state:"pause", remaining:($remaining | tonumber), floor:$floor,
       reason:"$\($remaining) left, at or under floor $\($floor)"}
    else
      {state:"ok", remaining:($remaining | tonumber), floor:$floor,
       reason:"$\($remaining) remaining"}
    end' 2>/dev/null) || {
  echo '{"state":"unknown","remaining":null,"floor":'"$FLOOR"',"reason":"could not parse /user/balance response"}'
  exit 3; }

echo "$OUT"
case "$(echo "$OUT" | jq -r .state)" in
  ok) exit 0 ;;
  pause) exit 10 ;;
  *) exit 3 ;;
esac
