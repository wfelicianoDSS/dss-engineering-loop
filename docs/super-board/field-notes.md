# Field notes — running super-board in production

Concrete failures met while operating a board, with the cause and the fix. Keep this list
current: every recurring failure here is a fix that should reach the scripts or the onboarding.

## Migrations

- **EF migrations live in module projects, not the API host.** Target the module that owns the
  context (`dotnet ef database update --project src/…/<Module>`). Pointing at the startup project
  fails with "no `DbContext` / no `Microsoft.EntityFrameworkCore.Design`".
- **Modules use per-module schemas with real dependencies.** Apply in dependency order. In
  FieldOps: `Users → Organizations → {Customers, Services, CrewManagement} → WorkManagement →
  Auditing`. An alphabetical loop fails with `3F000: schema "users" does not exist`.
- **The app database may need extensions.** The same migrations fail on a plain Postgres with
  `extension "postgis" is not available`. The database, not the ordering, is the problem.
- **No reachable database means the gate cannot be satisfied.** A "live" migrate step assumes a
  live DB. Either configure a real DB or declare that the deploy pipeline applies migrations
  (`commands = "-"`); do not leave a gate that can never pass.

## Providers

- **Two vendors can run dry together.** A long pause TTL then leaves `no provider available` for
  hours while cards sit still.
- **A paused provider rarely clears early.** The usage probe returns `unknown` for Claude/Codex
  (no plan snapshot), so the provider waits the full TTL even if it recovered in minutes.
- **Fix:** keep at least one provider live, prefer the one with quota, shorten or re-probe the
  pause, and alert when a lane cannot get a provider.

## Grooming

- **A full groom agent every tick is a large token drain** and starves Build/QA/Review of the same
  quota. Gate it on `Ready <= groom.ready_floor` and on the backlog actually changing
  (`count:max` signature + `groom.cooldown_seconds`).
- **The groom skips a provisional story with an open scope question — by design.** Surface the
  decision to the owner; do not loosen the "no invented scope" guardrail.

## GitHub reads

- **`gh api … --paginate --slurp` returns a list of pages.** A validator written for a single
  object/page shape throws a raw `TypeError` (e.g. `list indices must be integers or slices, not
  str`) and halts the run. Validate every page and preserve the output shape.
- **The same kind can carry two shapes.** Dependency reads use GraphQL
  (`data.repository.issues`), while an API list read is REST pages. Either classify by the command
  or accept both shapes in the validator.

## Merge policy

- **Keyword gates scan added lines.** Test files legitimately contain SQL literals (`delete from`)
  to prove a constraint (e.g. a foreign key `RESTRICT` blocks a cascade). That is not a
  destructive production operation — exclude `**/tests/**` from the keyword scan so tests do not
  trip a `destructive-data` human gate.

## Locks and restarts

- **Killing the runner leaves `inflight/<issue>` locks.** The automatic stale-lock reap only covers
  Building; a card in QA/Review can strand with no worker and never be re-dispatched. Clear the
  lock for the dead pid.
- **The checkout drifts onto feature branches.** Sync it to the base branch before restarting, or
  the runner reads old control-plane code.

## Fix agents

- **A watchdog that dispatches a Codex/Claude "fix agent" spends worker quota on board plumbing.**
  If board fixes must stay personal, disable the LLM fixer and escalate to the orchestrator
  instead.

## Runner fixes validated on FieldOps (headless dispatcher)

Implemented and verified in a live headless run. The workflow-based pack has no equivalent, so
these live in the runner rather than here.

- **No-provider visibility.** When a lane cannot get a provider, the runner writes a throttled
  entry (once per 30 min) to `.claude/super-board/needs-attention.log` — a frozen pipeline is no
  longer visible only in the run log.
- **Pause TTL 5h → 30m.** A vendor-limit pause clears after 30 minutes, so a recovered provider
  returns promptly. Still keep at least one provider live.
- **Per-tick stale-lock reap.** Dead `inflight/<issue>` locks are swept every tick, not only at
  startup, so a restart-stranded QA/Review card recovers without a manual unlock.
- **Restart guard.** The runner refuses to start while an orphaned
  `claude -p … super-board run` worker exists; stop orphans first
  (`pkill -f 'claude -p .*super-board run'`), otherwise the new runner exits and only the guard
  remains.
- **Stalled-with-work is visible.** The watchdog already detects "runner up but idle with N
  pending cards" (two consecutive stalled checks, then a restart). With the LLM fixer disabled it
  now writes a `needs-attention.log` entry and sends the configured notification instead of
  spending worker quota; a second failure escalates.
- **Kind is classified by payload, not command.** `kind issues` accepts either the GraphQL
  dependency-page shape or REST `--paginate --slurp` pages. Classifying by the command would
  reject a mislabeled caller; payload-first validates what actually arrived, which is safer.
