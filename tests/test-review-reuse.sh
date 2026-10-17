#!/usr/bin/env bash
# Review reuse — a merged PR goes to Done without a second merge, and an approved
# review of the current head dispatches merge-only instead of a full re-review.
#
#   bash tests/test-review-reuse.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n   expected: %s\n   actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") cat "$PR_LIST" ;;
  "pr view") cat "$PR_COMMENTS" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export SB_LIB_ONLY=1 SB_GITHUB_HALT_FILE="$TMP/halt.json"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/super-board-run.sh"
# The runner prepends its own tool dirs at source time; put the stub first again.
export PATH="$TMP/bin:$PATH"
set +e

# 1 — pure policy branches.
is "merged → done" "done" "$(review_decision '2026-10-17T12:00:00Z' abc def)"
is "approved at head → merge" "merge" "$(review_decision '' abc '' approve abc)"
is "approved stale head → review" "review" "$(review_decision '' abc '' approve old)"
is "bounce → review" "review" "$(review_decision '' abc '' bounce abc)"
is "no verdict → review" "review" "$(review_decision '' abc '' '' abc)"

# 2 — review_reuse parses the PR and its newest verdict/head lines.
PR_LIST="$TMP/list.json"; PR_COMMENTS="$TMP/comments.json"
export PR_LIST PR_COMMENTS
printf '%s' '[{"number":42,"state":"OPEN","headRefOid":"abc","mergedAt":null,"mergeCommit":null,"body":"Closes #7"}]' > "$PR_LIST"
printf '%s' '[{"body":"old\nreview-verdict: bounce\nreviewed-head: old"},{"body":"final\nreview-verdict: approve\nreviewed-head: abc"}]' > "$PR_COMMENTS"
review_reuse 7
is "approved PR reuse → merge" "merge" "$REVIEW_MODE"
is "reviewed head captured" "abc" "$REVIEW_HEAD"
is "PR number captured" "42" "$REVIEW_PR"

# 3 — merged PR → done (even with no verdict).
printf '%s' '[{"number":42,"state":"MERGED","headRefOid":"abc","mergedAt":"2026-10-17T12:00:00Z","mergeCommit":{"oid":"def"},"body":"Fixes #7"}]' > "$PR_LIST"
printf '%s' '[]' > "$PR_COMMENTS"
review_reuse 7
is "merged PR reuse → done" "done" "$REVIEW_MODE"

# 4 — unrelated PR body is not this card's PR.
printf '%s' '[{"number":9,"state":"OPEN","headRefOid":"abc","mergedAt":null,"mergeCommit":null,"body":"Closes #70"}]' > "$PR_LIST"
review_reuse 7
is "unrelated PR → full review" "review" "$REVIEW_MODE"
is "no PR number" "" "$REVIEW_PR"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
