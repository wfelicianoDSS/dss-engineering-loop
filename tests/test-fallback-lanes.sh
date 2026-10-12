#!/usr/bin/env bash
# Stubbed OpenCode harness only: the OpenRouter and DeepSeek fallback lanes'
# contract — Review refused, usage_fallback gate, model precedence + provider
# prefix, verdict parsing and exit codes. No network, no real provider call.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo"
git init -q "$T/repo"
export SB_OC_TEST_LOG="$T/calls.jsonl"
export PATH="$T/bin:$PATH"

# Stub the OpenCode harness: log the args (to assert the model), emit one JSONL
# text event carrying the lane verdict, exactly as the real `opencode run
# --format json` stream does.
cat > "$T/bin/opencode" <<'PY'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
model = args[args.index('-m') + 1] if '-m' in args else 'none'
with open(os.environ['SB_OC_TEST_LOG'], 'a') as log:
    log.write(json.dumps({'args': args, 'model': model}) + '\n')
status = os.environ.get('SB_OC_TEST_STATUS', 'advanced')
column = os.environ.get('SB_OC_TEST_COLUMN', 'QA')
text = 'not json' if os.environ.get('SB_OC_TEST_INVALID') else json.dumps(
    {'status': status, 'column': column, 'detail': 'stub lane result'})
print(json.dumps({'type': 'text', 'part': {'text': text}}))
sys.exit(int(os.environ.get('SB_OC_TEST_EXIT', '0')))
PY
chmod +x "$T/bin/opencode"
export SUPER_BOARD_OPENCODE_BIN="$T/bin/opencode"

cd "$T/repo"
CARD='{"number":1,"status":"Ready","title":"example"}'
fail() { echo "FAIL: $*" >&2; cat "$T/stderr" >&2; exit 1; }
last_model() { tail -1 "$SB_OC_TEST_LOG" | jq -r '.model'; }
run() {
  local script="$1" lane="$2" model="${3:-}"
  if [ -n "$model" ]; then
    bash "$KIT/scripts/$script" --config "$T/config.json" --card "$CARD" --lane "$lane" --model "$model" >"$T/out" 2>"$T/stderr"
  else
    bash "$KIT/scripts/$script" --config "$T/config.json" --card "$CARD" --lane "$lane" >"$T/out" 2>"$T/stderr"
  fi
}

check_leg() { # LEG SCRIPT DEFAULT_MODEL CONFIG_MODEL
  local LEG="$1" SCRIPT="$2" DEFAULT="$3" CFGMODEL="$4"
  echo "== $LEG leg =="

  # Review is never owned by a fallback lane (the script's choices are build|qa).
  local rc=0
  bash "$KIT/scripts/$SCRIPT" --config "$T/config.json" --card "$CARD" --lane review >"$T/out" 2>"$T/stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "$LEG: review must be refused (got $rc)"

  # Without this leg in usage_fallback the launcher refuses (78) before any call.
  echo '{}' > "$T/config.json"
  : > "$SB_OC_TEST_LOG"
  rc=0; bash "$KIT/scripts/$SCRIPT" --config "$T/config.json" --card "$CARD" --lane build >"$T/out" 2>"$T/stderr" || rc=$?
  [ "$rc" -eq 78 ] && [ ! -s "$SB_OC_TEST_LOG" ] || fail "$LEG: missing usage_fallback must refuse before dispatch"

  # Default model carries the provider prefix.
  printf '{"usage_fallback":["%s"]}\n' "$LEG" > "$T/config.json"
  run "$SCRIPT" build
  jq -e '.status == "advanced"' "$T/out" >/dev/null || fail "$LEG: advanced verdict not parsed"
  [ "$(last_model)" = "$DEFAULT" ] || fail "$LEG: default model $(last_model) != $DEFAULT"

  # config.<leg>.model wins; an already-prefixed value is not doubled.
  printf '{"usage_fallback":["%s"],"%s":{"model":"%s"}}\n' "$LEG" "$LEG" "$CFGMODEL" > "$T/config.json"
  run "$SCRIPT" build
  [ "$(last_model)" = "$CFGMODEL" ] || fail "$LEG: config model $(last_model) != $CFGMODEL"

  # --model beats config, still prefixed.
  run "$SCRIPT" build flag/model
  [ "$(last_model)" = "$LEG/flag/model" ] || fail "$LEG: flag model $(last_model) != $LEG/flag/model"

  # A verdict that is not parseable -> failed (exit 1).
  printf '{"usage_fallback":["%s"]}\n' "$LEG" > "$T/config.json"
  rc=0; SB_OC_TEST_INVALID=1 run "$SCRIPT" build || rc=$?
  [ "$rc" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail "$LEG: unparseable verdict must fail"

  # A halted verdict -> exit 79.
  rc=0; SB_OC_TEST_STATUS=halted run "$SCRIPT" build || rc=$?
  [ "$rc" -eq 79 ] && jq -e '.status == "halted"' "$T/out" >/dev/null || fail "$LEG: halted verdict must exit 79"
}

check_leg openrouter super-board-openrouter-lane.sh openrouter/deepseek/deepseek-v4-flash openrouter/foo/bar
check_leg deepseek   super-board-deepseek-lane.sh   deepseek/deepseek-flash                 deepseek/foo/bar

echo "PASS: test-fallback-lanes.sh (review refusal / usage_fallback gate / model precedence / verdict / exit codes)"
