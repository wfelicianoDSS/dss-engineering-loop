#!/usr/bin/env bash
# super-board-promote.sh — promote staging into main with a real PR + merge.
#
# Cards land in `staging`; `main` is production. This closes the manual gap: it opens
# (or reuses) a staging → main promotion PR and merges it, so merged cards reach main
# without a person doing it by hand. A promotion PR has head == base_branch, which the
# merge gate already understands (it must NOT --delete-branch, or it deletes staging).
#
# Safety rails (all conservative — it prefers to do nothing):
#   * no-op when main already contains staging;
#   * no-op unless main is an ancestor of staging (a real fast-forward shape, no conflict);
#   * settle time: skip until the newest staging commit is older than PROMOTE_SETTLE
#     seconds (default 300), so a just-merged card is not promoted the instant it lands;
#   * reuses an existing open staging → main PR instead of opening a duplicate.
#
# It only ever touches `main` and `staging`; it never force-pushes and never deletes a
# branch. Usage: super-board-promote.sh [--dry-run]
set -u
DRY_RUN=0; [ "${1:-}" = "--dry-run" ] && DRY_RUN=1
export PATH="$HOME/.local/bin:$HOME/.local/node/bin:$HOME/.opencode/bin:$HOME/.dotnet:$PATH"
cd "${SB_REPO_PATH:-$HOME/fieldops}" || exit 0
SETTLE="${PROMOTE_SETTLE:-300}"
LOG="${SB_PROMOTE_LOG:-/tmp/board-promote.log}"
log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

git fetch -q origin main staging 2>/dev/null || { log "fetch failed"; exit 0; }
STAGING=$(git rev-parse origin/staging) || exit 0
MAIN=$(git rev-parse origin/main) || exit 0
[ "$STAGING" = "$MAIN" ] && exit 0                       # already in sync
# Nothing to promote when main already contains every staging commit. (After a prior
# merge-commit promotion main sits *ahead* of staging, so this — not the reverse — is
# the correct no-op test.)
git merge-base --is-ancestor origin/staging origin/main && exit 0

NEWEST=$(git log -1 --format=%ct origin/staging) || exit 0
AGE=$(( $(date +%s) - NEWEST ))
[ "$AGE" -ge "$SETTLE" ] || { log "staging moved ${AGE}s ago (< ${SETTLE}s settle) — waiting"; exit 0; }

PR=$(gh pr list --base main --head staging --state open --json number -q '.[0].number' 2>/dev/null || true)
BODY="## Promotion\n\nAutomated \`staging → main\` promotion.\n\nCommits:\n$(git log --oneline origin/main..origin/staging | head -30)"
if [ -z "${PR:-}" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would open + merge a staging→main PR"; exit 0; fi
  PR=$(gh pr create --base main --head staging --title "🚀 promote: staging → main" --body "$(printf '%b' "$BODY")" 2>&1 | grep -oE '[0-9]+$' || true)
  [ -n "${PR:-}" ] || { log "could not open promotion PR"; exit 0; }
  log "opened promotion PR #${PR}"
else
  log "reusing open promotion PR #${PR}"
fi
if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would merge PR #${PR}"; exit 0; fi
if gh pr merge "$PR" --merge 2>&1 | tail -3 >> "$LOG"; then
  log "promoted staging (${STAGING:0:7}) → main via PR #${PR}"
else
  log "promotion merge of #${PR} failed — likely conflicts; needs a human rebase"
fi
