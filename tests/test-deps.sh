#!/usr/bin/env bash
# Tests super-board-deps.sh — the `## Blocked by` parser. No gh calls: the issue
# payload is injected with --from.
#
# Every scenario here is a shape that was observed on a real board, not an
# invented edge case. The parser exists because three of them silently produced
# "no blockers" and got cards built against a base branch that did not have what
# they needed.
set -euo pipefail
cd "$(dirname "$0")"
DEPS="../scripts/super-board-deps.sh"
FIX=fixtures/deps-issues.json

fail() { echo "FAIL: $1" >&2; exit 1; }
OUT=$("$DEPS" --from "$FIX")
get() { echo "$OUT" | jq -e ".[\"$1\"] | $2" >/dev/null; }

# 1 — the banner decoy. Every super-board ticket quotes the words "## Blocked by"
#     in its preflight banner. A parser that takes the FIRST match reads the
#     banner and reports no blockers on every card in the repo.
get 1 '.blockers == [2]'    || fail "#1 should read one blocker past the banner: $(echo "$OUT" | jq -c '.["1"]')"
get 1 '.parseable == true'  || fail "#1 should be parseable"
get 1 '.runnable == false'  || fail "#1 waits on open #2"

# 2 — an explicit None is an answer, and it makes the card runnable.
get 2 '.blockers == [] and .parseable == true and .runnable == true' || fail "#2 should be free"

# 3 — openBlockers is derived from who is actually open, so a closed blocker
#     drops out and stops holding the card.
get 3 '.blockers == [2,99]'   || fail "#3 should list both blockers"
get 3 '.openBlockers == [2]'  || fail "#3: #99 is closed and must not hold the card"

# 4 — THE LANDMINE. `- None — but #2 must be merged first.` A human reads one
#     blocker; a naive parser reads the word None and builds it. Neither answer
#     is safe to guess, so it is unparseable and fail-safe.
get 4 '.parseable == false' || fail "#4 says None and names an issue — must not be trusted"
get 4 '.runnable == false'  || fail "#4 must never be runnable"
get 4 '.why | test("None")' || fail "#4 must explain itself so the line can be fixed"

# 5 — no section is not the same as None. Nobody wrote it down, so nobody knows.
get 5 '.parseable == false and .runnable == false' || fail "#5 has no section and must be fail-safe"
get 5 '.why | test("silence")' || fail "#5 should say why a missing section is not None"

# 6 — an empty section is the same problem with a heading on top.
get 6 '.parseable == false and .runnable == false' || fail "#6 empty section must be fail-safe"

# 7 — prose with no bullet and no None. Unreadable.
get 7 '.parseable == false and .runnable == false' || fail "#7 prose-only must be fail-safe"

# 8 — the section stops at the next heading. An issue mentioned under "## Notes"
#     is not a blocker, and swallowing it would invent a dependency that holds a
#     free card forever.
get 8 '.blockers == []'   || fail "#8 must not read #2 from the following ## Notes section"
get 8 '.runnable == true' || fail "#8 is free"

# 9 — a blockquote under the bullet may name a past blocker as history. Only the
#     bullet is the machine-read line, so the note does not break the parse.
get 9 '.parseable == true and .runnable == true' \
  || fail "#9: a historical note in a blockquote must not make the section unreadable"

# 10 — --issues narrows the output without changing any verdict.
ONE=$("$DEPS" --from "$FIX" --issues 4)
echo "$ONE" | jq -e 'keys == ["4"]' >/dev/null || fail "--issues should return only what was asked for"
echo "$ONE" | jq -e '.["4"].parseable == false' >/dev/null || fail "--issues must not change the verdict"

# 11 — no --repo and no --from is a usage error, never an empty graph. An empty
#      graph read as "nothing blocks anything" is the worst possible failure.
RC=0; "$DEPS" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 64 ] || fail "missing --repo should exit 64, got $RC"

# ---- the `blocked-by:` line the lanes write into Block comments ----------
# Documented in block-template.md as mandatory. It was documented before it was
# read, which is its own kind of bug: a machine line nothing consumes.

# 12 — a Block comment's `blocked-by:` outranks the body. The lane that just
#      parked the card knows why; the body may be weeks older.
get 20 '.blockers == [2,99]' || fail "#20: the comment line should win over the body's None"
get 20 '.parseable == true'  || fail "#20 should be parseable"
get 20 '.runnable == false'  || fail "#20 waits on open #2"

# 13 — `blocked-by: -` is a HUMAN gate, not "no blockers". Credentials, perms and
#      product decisions all use it. Parseable, deliberately never runnable, and
#      the sweep must leave it alone rather than cheerfully freeing it.
get 21 '.parseable == true'  || fail "#21: `-` is a valid answer"
get 21 '.humanGated == true' || fail "#21 should be flagged as human-gated"
get 21 '.runnable == false'  || fail "#21 must never be swept back to Ready by a bot"
get 21 '.blockers == []'     || fail "#21 has no issue blockers, just a person"

# 14 — the newest comment wins. A card blocked on #2, then updated to a human
#      gate, must not be freed when #2 closes.
get 22 '.humanGated == true' || fail "#22: the LAST blocked-by line should win"
get 22 '.runnable == false'  || fail "#22 must stay parked"

# 15 — a malformed line is fail-safe, exactly like a malformed body section.
get 23 '.parseable == false' || fail "#23: `none, but #2 first` must not be trusted"
get 23 '.runnable == false'  || fail "#23 must not run"
get 23 '.why | test("issue numbers alone")' || fail "#23 must say what the line should look like"

# 16 — no comments at all: the body still governs, unchanged.
get 24 '.blockers == [2] and .runnable == false' || fail "#24: the body should still be read"

# 17 — issues with no `comments` key at all (the older payload shape) still parse.
#      Scenarios 1–11 above all use that shape, so reaching here proves it.
get 1 '.blockers == [2]' || fail "a payload without a comments key must still parse"

# 18 — 🙋 needs you. A 🙋 Block comment marks the card needsYou and keeps it
#      human-gated. Bare done comments and labels cannot prove head/authority;
#      only the live approval helper can mark needsYouDone (test_approval.py).
get 25 '.needsYou == true and .needsYouDone == false and .runnable == false' || fail "#25 waits on a human"
get 26 '.needsYouDone == false' || fail "#26: a bare done with no verified head/request cannot authorize"
get 27 '.needsYouDone == false' || fail "#27: a label alone cannot authorize"
get 28 '.needsYouDone == false' || fail "#28: a 'done' before the 🙋 block must not count"
get 26 '.runnable == false'     || fail "#26: done goes through resume, never the Ready sweep"
get 2  '.needsYou == false and .needsYouDone == false' || fail "an ordinary card is not needsYou"

# ---- block-class: / resume-when: (block-template.md) ---------------------
# 19 — transient with the ⚙️ tag, waiting on a provider. The condition needs live
#      provider state, so the offline parser reports it as not runnable here.
get 30 '.blockClass == "transient" and .resumeWhen == "provider-available:build"' || fail "#30 should keep its transient condition"
get 30 '.attempts == 1' || fail "#30 should carry its attempts"
get 30 '.rootCause == "rc-abc123"' || fail "#30 should carry its root cause"
get 30 '.runnable == false' || fail "#30 cannot be judged offline"

# 20 — after:<past> has passed, after:<future> has not. This is the one transient
#      condition the parser can decide without GitHub or a provider probe.
get 31 '.blockClass == "transient" and .runnable == true' || fail "#31 should be free once the instant passed"
get 32 '.blockClass == "transient" and .runnable == false' || fail "#32 must wait for its instant"

# 21 — THE TAG WINS. A credential wall that claims `transient` is a human block;
#      no sweep may retry it as if it were a timeout.
get 33 '.blockClass == "human" and .humanGated == true and .runnable == false' \
  || fail "#33: 🔐 must never be transient"

# 22 — the third transient block of one root cause escalates to a human decision.
get 34 '.escalated == true' || fail "#34 should escalate on the third occurrence"
get 34 '.blockClass == "human" and .humanGated == true and .runnable == false' \
  || fail "#34 must stop being swept after escalation"

# 23 — a transient block waiting on issues clears exactly like a dependency.
get 35 '.blockClass == "transient" and .resumeWhen == "issues-closed:99"' || fail "#35 should read its condition"
get 35 '.runnable == true' || fail "#35: all listed issues are closed"

# 24 — a transient block with no condition never clears itself (fail safe).
get 36 '.blockClass == "transient" and .resumeWhen == "never" and .runnable == false' \
  || fail "#36 must not resume without a condition"

echo "PASS: test-deps.sh (24 scenarios)"
