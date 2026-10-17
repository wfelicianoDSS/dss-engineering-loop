# The orchestrator

> The interactive session that starts a run is an **orchestrator, not a worker**. It owns the
> board's control plane and its operating budget; it never does product work.

The board runs Build → QA → Review → merge on its own. The orchestrator keeps that machine
healthy: it starts and restarts the runner, triages stalls, manages provider budget, and
surfaces the decisions the board must not invent.

## What the orchestrator owns

| Area | Responsibility |
|---|---|
| Lifecycle | Start / stop / restart the headless runner; keep the checkout on the base branch |
| Triage | Read the halt file, runner log, worker logs, card history; find the root cause |
| Control plane | Fix `.claude/bin/**`, config, skills, hooks — the board's own plumbing |
| Budget | Provider order, pauses, fallback, grooming cadence |
| Decisions | Surface scope questions the groom refuses to guess; resolve human gates |
| Reporting | Say what changed, what is blocked, and why |

## What it never does

- **No product work.** It does not build, QA, review or merge product cards, and it does not
  edit application code. Those belong to the lanes.
- **Board fixes are personal.** Control-plane fixes are made by the orchestrator directly:
  never filed as board tickets, and never delegated to Codex or Claude (owner rule). Those
  budgets are for product stories.
- **No history rewriting.** No force-push, no rebase of shared history, no direct commits to
  the protected base branch — fix through a branch + PR you own.
- **Never read `.env`.** Key names via the project's env-check helper only.

## The loop

**Observe → diagnose → smallest fix → verify → restart → confirm.**

1. **Observe.** Read the runner log tail, `.claude/super-board/github-halt.json`, the newest
   `worker-*.log`, and the card's own history before changing anything. The board's state is
   the GitHub Project; the logs explain why it stopped.
2. **Diagnose.** Find the failure class (table below). Do not restart blindly: a restart that
   does not address the cause returns to the same state, and a restart can strand in-flight
   cards (see *stale locks*).
3. **Fix the smallest thing.** A one-line validator change beats a refactor. Test it
   (`bash -n`, the script's unit tests, `jq -e .` on JSON) before committing.
4. **Land it yourself.** Branch off the base, commit, open a PR, merge it — not through the
   board's lanes.
5. **Restart and confirm.** `super-board-autostart.sh` sets `lane_backend` and reconciles a
   stale *read* halt. Confirm the next tick dispatches on the intended provider.
6. **Record it.** Append one line to `.claude/super-board/interventions.jsonl` for every manual
   action: `{"at":"<iso>","class":"<failure class>","card":<n|null>,"action":"<what>","minutes":<n>}`.
   The class comes from the failure table below. `super-board-status.py --metrics` reads the
   ledger; an action with no line cannot be counted, so no improvement can be proven.

## Failure classes

| Symptom | Diagnose | Fix |
|---|---|---|
| `[github-read] HALT` | `.claude/super-board/github-halt.json` — the recorded operation and reason | Fix the read/validator (see [field notes](field-notes.md#github-reads)); reconcile a *read* halt via `--resume`; restart |
| `no provider available for lane=…` every tick | `provider-pauses/` and the provider order | Prefer an available provider; never leave both parked while work is pending |
| Card in Review, no worker, no merge | `inflight/<issue>` lock with a dead pid | Clear the stale lock; the automatic reap only covers Building |
| `↻ n/n` rebuild cap | The card's review/QA findings | If quality is good, clear/raise the cap; if scope is missing, escalate |
| Repeated identical grooms | `worker-groom.log` | Expected when the backlog is unchanged; derate with `ready_floor` + `cooldown_seconds` |
| Runner down, guard alive | Log tail + halt file | Reconcile, then autostart |
| Checkout on a feature branch | `git branch --show-current` | Sync to the base before restarting |

## Provider budget

- Order is per lane and read on every dispatch: `usage_order` (build/QA), `review.providers`,
  `groom.providers`.
- A vendor limit parks that provider. A paused provider clears early only on a fresh usage
  snapshot; Claude/Codex often report `unknown`, so it waits the pause TTL. Keep at least one
  provider live and prefer the one with quota.
- Park metered providers (e.g. DeepSeek) and keep the board on plan providers; reserve the
  metered balance for the orchestrator.
- Before blaming providers for slowness, check the grooming cadence: a full groom agent every
  tick is a large, unnecessary drain.

## Scope and human gates

- The groom **will not invent scope**. A provisional story with an open decision is skipped and
  the question is recorded. Surface it to the owner, post the decision on the issue, then force
  the next groom.
- **Migrations** and **destructive-data** are human gates by config. Verify the card's quality
  first; then either resolve the step (run it, or accept that the deploy applies it) and
  comment `done`, or change the policy. Never merge a card whose evidence does not hold.

## Guardrails

- One control-plane change at a time; verify before restarting.
- Keep the board's own state (`provider-pauses/`, `inflight/`, `card-halts/`, `github-halt.json`)
  truthful — never delete halt evidence to "unblock".
- Record every recurring failure in [field notes](field-notes.md) so the next run does not
  rediscover it.
