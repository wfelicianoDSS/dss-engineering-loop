#!/usr/bin/env bash
# super-board-evidence-check.sh — reject hand-authored / fabricated evidence.
#
# QA and the Reviewer commit tool output as proof, but an agent can also *hand-write* a file at a
# tool's output path so it looks like proof (2026-10-15: a 75-line hand-written
# `coverage.cobertura.xml` with a descriptive `scope` attribute was committed as coverlet output).
# This validates the known tool-output files structurally and fails loud, so a fabricated artifact
# can never carry a QA Pass or a Reviewer merge.
#
# Usage: super-board-evidence-check.sh <evidence-dir>
#   e.g. super-board-evidence-check.sh docs/super-board/runs/issue-237-qa-v1
# Exit: 0 ok · 1 a file is not genuine tool output · 64 usage.
set -euo pipefail

dir="${1:-}"
[ -n "$dir" ] || { echo "usage: $0 <evidence-dir>" >&2; exit 64; }
[ -d "$dir" ] || { echo "no such evidence dir: $dir" >&2; exit 64; }

fail=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # Every real Cobertura producer (coverlet, coverage.py, JaCoCo-cobertura) emits <sources> and
  # <packages>. A hand-written "cobertura" snippet has neither.
  if ! grep -q '<sources' "$f" || ! grep -q '<packages' "$f"; then
    echo "✗ $f — not valid Cobertura output (missing <sources>/<packages>); hand-authored?" >&2
    fail=1
  fi
done < <(find "$dir" -type f -iname '*cobertura*.xml')

if [ "$fail" -ne 0 ]; then
  echo "✗ evidence check failed — commit the tool's raw output, not a hand-written summary" >&2
  exit 1
fi
echo "✅ evidence check: ok"
