# Autonomy plan — adapted to the FieldOps headless runner

> Adaptation of `autonomy-plan.md` for the **headless tick-loop runner** that actually drives
> FieldOps (`.claude/bin/super-board-run.sh`, ~1,150 lines), not the workflow pack. Same goal,
> same ground rules; every PR names the concrete file + function it touches and the test that
> proves it.

## Goal (unchanged)

A well-specified story goes Build → QA → Review → merge with **no orchestrator action** unless
a product, security, destructive-data or permission decision needs the owner. The orchestrator
becomes an exception handler.

**Design rule:** policy in scripts, judgment in agents. A recovery decidable from observable
state (board, lease, PR head, halt record, provider state) is a script with a test; an LLM is
called only when no policy applies.

## Why this adaptation differs from the pack plan

| Pack assumption | FieldOps reality |
|---|---|
| Orchestrator LLM runs wave steps from `run-workflow.md` | The runner is a 5-minute **tick loop** in one bash process; no per-wave LLM steps |
| `scripts/` is the source of truth | The pilot runs `.claude/bin/` (installed copies); the two have drifted |
| Recovery is described in prose | Recovery is bash functions inside `super-board-run.sh` |
| Grooming is a skill call | `dispatch_groom` in the runner, already derated |
| Provider choice per wave | `lane_provider()` over `usage_order` / `review.providers` / `groom.providers` + pause files |

Existing runner functions this plan builds on:

- `dispatch_lane` — provider pick → lock → spawn a lane worker.
- `lane_provider` / `provider_dispatch_allowed` / `pause_provider` — selection, pause files, TTL.
- `reap_finished_locks` — dead-pid sweep (now every tick).
- `reclaim_stranded_building` — Building-only recovery.
- `sweep_blocked_by` / `sweep_lane_zombies` — dependency and zombie sweeps.
- `dispatch_groom` — intake lane with `groom.ready_floor` + backlog signature/cooldown.
- `halt_cleanup` + `super-board-github-read.py` — halt file + `--resume`.
- `gh_rate_guard` / `fetch_project_items` / `column_count` — board snapshot.
- Separate `super-board-guard.sh`, `super-board-watchdog.sh`, `super-board-autostart.sh`.

## Ground rules (binding)

1. **One PR at a time**, in order; landed by the orchestrator personally (branch off `staging` →
   PR → merge). Never through the board's lanes.
2. **Never patch the live runner mid-tick.** Change scripts, then restart (autostart) and
   observe ≥ 20 ticks.
3. **Tests first**, offline with stubbed `gh` (the `evals/_stubs/bin/gh` style). A failing test
   reproduces the field-note failure before the fix.
4. Formats change in `writing-standard.md` first, then `block-template.md`, then the format test.
5. Each PR: release-note entry + a `field-notes.md` line marking the note `✅ fixed in vX.Y.Z —
   test: <path>`.
6. **Never widen agent authority.** No agent decides 🔐 💳 🔑 ❓ 🛡 🧑 🎨 🙋 items, protections,
   hooks, guard scripts, approval rules or halt semantics.
7. **Auto-tune only toward caution** (fewer workers, longer pauses, more gates). Loosening is an
   owner-approved PR.
8. **Never retry an uncertain write.** Inspect the remote outcome read-only first.

---

## Phase 0 — PR 0 · 📏 Intervention ledger + autonomy metrics

**Targets:** new `scripts/super-board-metrics.py`; `scripts/super-board-status.py` (`main`, add
`--metrics` delegation); `docs/super-board/orchestrator.md` (ledger rule); new
`tests/test_metrics.py`.

**Change**
- Append-only `.claude/super-board/interventions.jsonl`; one line per manual action:
  `{"at":"<iso>","class":"<class>","card":<n|null>,"action":"<what>","minutes":<n>}`.
  Class vocabulary: `github_read_halt, no_provider, stale_lock, rebuild_cap, groom_repeat,
  runner_down, branch_drift, scope_decision, human_gate, other`.
- `super-board-metrics.py --config <cfg> [--since <iso>] [--items <json>]` prints:
  Done count, interventions total + by class, interventions per 100 Done. (Median Blocked time
  and wasted dispatches are added by PR 5 and PR 8, where the data exists.)
- `status.py --metrics` delegates to it with the resolved config.
- `orchestrator.md` "The loop" step 5: append a ledger line for every manual action.

**Test:** fixture ledger + items JSON → exact counts and per-100 value; unknown class warns.

**Done when:** `super-board-metrics.py` runs on the pilot and the owner has a baseline.

---

## Phase 1 — PR 1 · ⬆️ Upstream the runner fixes into `scripts/`

**Targets:** `scripts/super-board-run.sh`, `scripts/super-board-github-read.py`,
new `scripts/super-board-watchdog.sh`, `scripts/super-board-guard.sh`,
`scripts/super-board-autostart.sh`; `install.sh` + `CLAUDE.md` install contract;
`skills/super-board/references/config-schema.json`.

**Change**
- Diff the pilot's `.claude/bin/` against `scripts/` and bring each change over **unchanged in
  behaviour**:
  - `run.sh`: `groom.ready_floor` + backlog signature/cooldown gate; `SB_PAUSE_TTL` 30 min;
    per-tick `reap_finished_locks`; no-provider `needs-attention.log` entry.
  - `github-read.py`: REST `--paginate --slurp` acceptance for `kind issues`.
  - `watchdog.sh`: stalled-with-work escalation writes `needs-attention.log`; no LLM fixer.
  - `autostart.sh` / `guard.sh`: restart contract, `lane_backend` reset, orphan guard.
- Document every key it reads in `config-schema.json` with defaults: `usage_order`,
  `review.providers`, `groom.providers`, `groom.ready_floor`, `groom.cooldown_seconds`,
  `lane_backend`, `notifications`, `migrations.*`.
- Add the new scripts to `install.sh` and the `CLAUDE.md` install contract.

**Tests:** `tests/test-provider-pause.sh`, `tests/test-needs-attention.sh`,
`tests/test-watchdog.sh` (stalled twice → one needs-attention entry, no fixer dispatched),
`tests/test-groom-gate.sh`.

**Done when:** a fresh `install.sh` into a scratch copy yields byte-identical control-plane
scripts to what the pilot runs now.

---

## Phase 1 — PR 2 · 🔒 Install drift guard

**Targets:** `install.sh` (manifest write + compare), `tests/test-install.sh`.

**Change:** write `.claude/super-board/install-manifest.json` (sha256 per installed file). On
reinstall, a target file whose hash differs from the manifest is locally modified: skip it,
print `kept local change: <path> — upstream it or pass --overwrite-local`, exit 0 with a
summary. `--overwrite-local` replaces and backs up to `<path>.local-<date>`.

**Test:** install → edit one bin script → reinstall → kept + reported; `--overwrite-local` →
replaced + backup present.

---

## Phase 1 — PR 3 · 🧪 Field notes → code + regression tests

**Targets:** `scripts/super-board-merge-policy.py`; `super-board-run.sh` (preconditions);
`tests/*`.

| Field note | State in the runner | Work |
|---|---|---|
| Keyword gate trips on test SQL | **Not fixed** in the pack copy; fixed in the pilot only | Add `merge_policy.keyword_exclude` (defaults incl. `**/tests/**`, `**/*Tests.cs`, `**/*.test.*`); paths still count for size. Test: `delete from` under `tests/` → no gate; under `src/` → gate |
| `--paginate --slurp` for `issues` | Fixed (payload-first) | Add the missing test: REST pages validate; malformed page → exit 64 / halt under strict |
| Migration gate can never pass without a DB | **Not in the runner** | Port precondition 7 of `run-workflow.md`: an `allowed_envs` env with a command and no check, and no `commands = "-"` → refuse to start with the config key to fix |
| Stale `inflight` locks for QA/Review | Fixed (per-tick reap) | Test: dead-pid lock on a Review card → lock removed, assignee released, re-dispatchable next tick |
| Checkout drifts onto a feature branch | **Not handled** | Runner precondition: `git branch --show-current` ≠ `base_branch` → refuse to start (exit 73) with the sync command; autostart syncs only when the tree is clean |
| EF migrations per module / order / PostGIS | Product-specific | Not a pack change: put it in the pilot's `CONSTRAINTS.md`/`AGENTS.md`, and make `migrations.commands.<env>` call one ordered pilot script |

Add to the top of `field-notes.md`: every entry ends with `test: <path>` or `no-test: <reason>`.

---

## Phase 2 — PR 4 · ⏯️ Classified halts + auto-resume for transient reads

**Targets:** `scripts/super-board-github-read.py` (halt record, `--resume`, new `--auto-resume`);
`super-board-run.sh` (`halt_cleanup` call site + tick).

- Halt file gains `class`: `transient_read` (timeout/5xx/network/secondary limit),
  `permanent_read` (auth/permission/invalid query), `shape` (strict validator rejection),
  `uncertain_write` (`--halt` after a mutation). Missing class = `permanent_read`.
- `--auto-resume`: only `transient_read`; reuse the `--resume` probe; track
  `auto_attempts` / `next_probe_at`; backoff 2, 5, 10, 20, 30, 30 min; after 6 failures stop and
  append one `needs-attention.log` line. Any other class exits non-zero, changes nothing.
- Runner tick: if halted, call `--auto-resume`, sleep to `next_probe_at` (keep the lane loop
  alive) instead of exiting.

**Tests** (`tests/test_github_reads.py`): class recorded per case; `--auto-resume` no-ops on
other classes; transient + success → cleared and archived; backoff honoured with `SB_NOW`;
6 failures → exactly one attention line.

---

## Phase 2 — PR 5 · 🧭 Machine-readable block classes

**Targets:** `writing-standard.md` → `block-template.md` → `super-board-deps.sh` (parse) →
`super-board-run.sh` (`sweep_blocked_by`) → `tests/test_writing_format.py`, `tests/test-deps.sh`.

- Two machine lines under every Block comment: `block-class: human | dependency | transient`
  and `resume-when: <condition>`.
- `resume-when`: `issues-closed:<n,…>`, `human-done`, `provider-available:<lane>`,
  `ci-rerun:<sha>`, `after:<iso>`, `never`.
- New reason tag ⚙️ Infra/transient — the only tag allowed with `transient`. 🔐 💳 🔑 ❓ 🛡 🧑 🎨
  are `human`; 🙋 is `human` + `human-done`; ⏳ and dependency waits are `dependency`.
- `transient` blocks carry `attempts: <n>`; the sweep returns the card to Ready when the
  condition verifies; the 3rd transient block of the same root-cause hash converts to `human`
  (🛡) + one attention line.
- Backward compatible: no `block-class:` → `human` unless `blocked-by:` lists issues
  (`dependency`).

**Tests:** human never swept; 🔐 declaring `transient` rejected by the format test and treated
as human; transient false stays, true sweeps; third occurrence converts; legacy parses as before.

---

## Phase 3 — PR 6 · 💓 Worker leases with heartbeat

**Targets:** `read_lock`/`write_lock` in `super-board-run.sh`; `super-board-github-read.py`
(`--check` heartbeat); lane spawn env.

- Lease v2 (keep `PID=` first): `PID= LANE= PHASE= STARTED= HEARTBEAT=<epoch> HEAD=<sha|->
  PROVIDER=<name>`.
- Heartbeat with **zero prompt changes**: when `SB_LEASE_FILE` is set, the `--check` that runs
  before every write/merge/dispatch rewrites `HEARTBEAT=` atomically. The runner exports it when
  spawning a worker.
- Reap: pid dead → today's path. Pid alive + heartbeat older than `lease_ttl_seconds` (2700) →
  one attention line; older than 2× → treat as hung: SIGTERM, keep the worktree, release the
  claim, card stays in column with a comment.

**Tests:** heartbeat only when `SB_LEASE_FILE`; v1 lock parsed; stale heartbeat + live pid →
attention then kill at 2×; dead pid unchanged.

---

## Phase 3 — PR 7 · ♻️ Reuse a finished review

**Targets:** `super-review` skill (verdict lines) → `super-board-run.sh` review dispatch.

- Reviewer comment gains `review-verdict: approve|bounce|block` and `reviewed-head: <full sha>`.
- Review card with no live lease → script decides:
  1. PR merged (`gh pr view --json mergedAt,mergeCommit`) → verify merge commit is an ancestor of
     base, move to Done. No merge attempt.
  2. Not merged, verdict `approve`, `reviewed-head` == current head → dispatch **merge only**:
     `super-board-merge-gate.sh --expect-head <reviewed-head>`.
  3. Head moved / no verdict / not approve → full review.
- Merge outcome unknown → step 1's read decides; never merge twice without it.

**Tests:** fixture PR states for each branch, incl. "merged but in Review" and "approved, head
changed".

---

## Phase 4 — PR 8 · 🔁 `super-board-reconcile.py` (single recovery contract)

**Targets:** new `scripts/super-board-reconcile.py`; `super-board-run.sh` tick (call it, then
dispatch its list); `super-board-card.sh`/`status.py` remain the snapshot source.

- `reconcile.py --config <cfg> [--apply]`; inputs: board snapshot, leases, halt file, provider
  state, planner output. Output JSON:
  `{dispatch:[{issue,lane,phase,provider}], recover:[…], resume:[…], sweep:[…], escalate:[…],
  noop_reason}`.
- `--apply` performs only the safe mutations already allowed (column moves, verified claim/
  release, standard comments, manifest lines). Dispatch stays with the caller.
- Runner: each tick `reconcile --apply`, then dispatch its `dispatch` list. Old helper functions
  move into the script or become thin wrappers.

**Invariants (each a test):** idempotent (second run zero writes); never dispatch a live lease or
non-bot assignee; never move a `human` block; with a halt only report (except `transient_read`);
crash between mutations converges (fail stubbed `gh` after N writes).

**Done when:** the orchestrator's per-tick work is one reconcile call + dispatches.

---

## Phase 5 — PR 9 · 🔀 Health-aware provider state

**Targets:** new `scripts/super-board-providers.py`; `super-board-run.sh`
(`provider_dispatch_allowed`, `pause_provider`, `lane_provider`); `providers/patterns.json`.

- `providers/<name>.json`: `{state: ok|paused|probing|open, paused_until, reason,
  consecutive_failures, last_success, probe_interval}`.
- Claude usage pause → `paused_until = resets_at + 60s`. Vendor limit with a reset time → parse
  it (patterns file built **only** from real worker-log lines). No reset time → `probing`: one
  card after 15 min; success → `ok`, failure → double to 60 min cap. Usage `unknown` → not
  exhausted, dispatch normally. 3 non-quota failures → `open` 30 min + one attention line.
  All providers paused/open → one alert, sleep to the earliest wake, no GraphQL ticks.
- Two thresholds: `usage.build_pause_pct` (85) and `usage.review_pause_pct` (95) — stop new Build
  first so QA/Review can drain. Metered providers stay out of lane order.

**Tests:** injected clock; fixture error strings; probe allows exactly one dispatch; circuit
opens/closes; all-paused wake time; reconcile consumes the state.

---

## Phase 6 — PR 10 · 🎫 Readiness certificates + event-driven grooming

**Targets:** `super-board-run.sh` (`dispatch_groom`); new
`scripts/super-board-groom-select.py`; the groom skill.

- After a story passes groom/lint, write
  `<!-- sb-ready v1 hash=<sha256(title+body+labels)[:12]> checks=ac,deps,scope,risk -->`.
- `groom-select.py` returns only Backlog issues with no certificate or a changed hash. Runs only
  when `Ready <= ready_floor` or the backlog signature changed, and the cooldown passed; empty
  list → no agent call.
- Unchanged: an open scope question → skipped, recorded, owner asked.

**Tests:** certified unchanged not selected; body edit selected; no trigger → no call.

---

## Phase 7 — later, only if metrics justify

- Weekly clustering of `interventions.jsonl` + `needs-attention.log` by class; a class seen ≥ 3
  times gets a **draft PR** with a failing fixture for the owner. Never merges itself, never
  touches hooks/guards/policy/approval/halt semantics.
- Adaptive model routing only after ≥ 100 Done cards with per-card provider/model/attempts.

## Out of scope

- A second always-on controller daemon: PR 8 evolves the existing runner.
- Agents resolving product scope, auth/trust, destructive data or public contracts.
- Delegating control-plane fixes to the board's lanes.

## Success criteria (measured with PR 0)

- Interventions per 100 Done down ≥ 70 %.
- Zero whole-run stops from `transient_read` or a single card's read.
- Zero repeated full reviews of an approved, unchanged head.
- Median non-human Blocked time < 1 hour.
- No new merges without the existing gate, approvals and ancestry check.
