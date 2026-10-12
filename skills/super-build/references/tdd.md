# Test-driven development (Builder)

The Builder writes the failing test first, then the smallest implementation that turns it
green, then refactors. This file is the mechanics; `super-build/SKILL.md` § Lifecycle is
the sequencing, and `../super-board/references/principles.md` is the judgment.

## Red → green → refactor

1. **RED** — write one failing test that calls the code the way its users do and asserts
   the observed result against a literal expected value. No mocking the thing under test
   into a tautology.
2. **GREEN** — the smallest change that makes it pass. No extra abstraction, no guard
   rails the test doesn't demand.
3. **REFACTOR** — clean up only after green, then run the suite again.

## Test sizes (the pyramid)

- **Unit — the bulk (~80%).** Fast, no network/DB. One unit, one behavior.
- **Integration (~15%).** A vertical slice against real Postgres and the object store
  (the Testcontainers fixture). This is where the AC's "tenant-scoped, persisted" claims
  are proven.
- **E2E (~5%).** A full user path, only where the risk justifies the cost.

## Rules

- **Beyonce rule** — if you liked it, you put a test on it. A changed behavior without a
  test is not done.
- **DAMP over DRY** — tests may repeat a little setup to stay readable. One test per
  behavior beats clever shared helpers.
- **One test, one reason** — a failing test should name the exact contract that broke.
- **A green test you wrote is necessary, not sufficient.** The Tester and Reviewer
  re-run independently; never call a card done on your own green.

## Prove it works (before handoff)

- Run the exact command the Tester will run and record it as the PR `Local tests:` line.
- For upload/import/background flows, verify the job reached a terminal state and the row
  persisted — an HTTP 200 or UI success is not evidence.
- Inspect the diff, not just the test summary: the smallest change that passes, no scope
  drift.
