# Autonomy plan — fewer interventions for the orchestrator

> Target location: `docs/super-board/autonomy-plan.md`. Audience: the orchestrator agent that
> owns the control plane (see `orchestrator.md`). Written against `main` @ 9785784 (v3.1.2).

## Goal

A well-specified story added to the board goes Build → QA → Review → merge with **no
orchestrator action** unless a product, security, destructive-data or permission decision
needs the owner. The orchestrator becomes an exception handler, not the control loop.

Design rule for every PR below: **policy in scripts, judgment in agents.** A recovery that can
be decided from observable state (board, PR head, lease, halt record, provider state) is
decided by a script with tests. An LLM is called only when no policy applies.

## Ground rules for executing this plan

1. **One PR at a time**, in the order below. Each PR is a control-plane fix landed by the
   orchestrator personally (branch off `main` → PR → merge). Never through the board's lanes.
2. **Never patch mid-run.** Stop the runner, land the PR, reinstall into the pilot project
   (`./install.sh <fieldops-path>`), restart, then observe at least 20 ticks / 1 wave.
3. **Tests first.** Each PR starts with a failing test that reproduces the field-note failure.
   `bash tests/run-safety.sh` must be green except `tests/test-get.sh` when running as root
   (known environment issue, not a regression).
4. **Formats change in `writing-standard.md` first**, then templates, then
   `tests/test_writing_format.py` (repo rule in `CLAUDE.md`).
5. Each PR: commit format from `CLAUDE.md`, one entry in `RELEASE-NOTES.md`, and a line in
   `field-notes.md` marking the note it closes as `✅ fixed in vX.Y.Z — test: <path>`.
6. **Do not widen agent authority.** Nothing here lets an agent decide 🔐 💳 🔑 ❓ 🛡 🧑 🎨 🙋
   items, change merge protections, hooks, guard scripts, approval rules or halt semantics.
7. **Auto-tuning only toward caution.** Scripts may narrow (fewer workers, longer pauses,
   more human gates) on their own. Loosening anything is an owner-approved PR.
8. **Never retry an uncertain write.** Inspect the remote outcome read-only first. This rule
   from `run-workflow.md` stays absolute in every new mechanism.

---

## Phase 0 — Measure (do first, it is small)

### PR 0 · 📏 Intervention ledger and autonomy metrics

**Why.** Without a count of interventions, no later PR can prove it helped.

**Change.**
- New append-only `.claude/super-board/interventions.jsonl`. The orchestrator appends one
  line for every manual action:
  `{"at":"<iso>","class":"<failure class>","card":<n|null>,"action":"<what>","minutes":<n>}`.
  `class` is a closed set taken from the failure-class table in `orchestrator.md`
  (`github_read_halt`, `no_provider`, `stale_lock`, `rebuild_cap`, `groom_repeat`,
  `runner_down`, `branch_drift`, `scope_decision`, `human_gate`, `other`).
- `scripts/super-board-status.py --metrics [--since <iso>]` prints:
  - autonomous completions (cards reaching Done with zero ledger lines naming them),
  - interventions per 100 Done cards,
  - median hours spent in Blocked, split human vs non-human class (after PR 5),
  - wasted dispatches: dispatches whose card did not change column before the next dispatch
    (from the run manifest's dispatch lines).
- Add a ledger line requirement to `orchestrator.md` → "The loop" step 5.

**Tests.** `tests/test_status_parse.py`: fixture manifest + ledger → exact metric values.

**Done when.** `status.py --metrics` runs on the pilot and the owner has a baseline number.

---

## Phase 1 — Stop losing fixes (P0)

### PR 1 · ⬆️ Upstream the FieldOps runner fixes

**Why.** The provider pauses, `needs-attention.log`, the watchdog/autostart, the 30 min pause
TTL and stall visibility described in `field-notes.md` exist only in the pilot's installed
`.claude/bin/`. They have no tests, and a reinstall copies `scripts/` over them.

**Change.**
- Diff the pilot's `.claude/bin/` against this repo's `scripts/` (and any
  `super-board-autostart.sh` / watchdog script that exists only there). Bring each change
  into `scripts/` unchanged in behaviour.
- Document every config key it reads (`usage_order`, `review.providers`, `groom.providers`,
  `groom.ready_floor`, `groom.cooldown_seconds`, `lane_backend`, notification settings) in
  `skills/super-board/references/config-schema.json` with defaults.
- Add the new scripts to the install contract in `CLAUDE.md` and `install.sh`.

**Tests.** One suite per behaviour, offline with the `evals/_stubs/bin/gh` style stubs:
`tests/test-provider-pause.sh`, `tests/test-needs-attention.sh`, `tests/test-watchdog.sh`
(stalled-with-work twice → one needs-attention entry, no LLM fixer dispatched).

**Done when.** A fresh `install.sh` into a scratch copy of the pilot yields byte-identical
control-plane scripts to what is running there now.

### PR 2 · 🔒 Install drift guard

**Why.** Prevents PR 1's problem from recurring.

**Change.** `install.sh` writes `.claude/super-board/install-manifest.json` (sha256 per
installed file). On reinstall, a target file whose hash differs from the manifest is locally
modified: skip it, print `kept local change: <path> — upstream it or pass --overwrite-local`,
exit 0 with a summary line. `--overwrite-local` replaces and backs up to `<path>.local-<date>`.

**Tests.** `tests/test-install.sh`: install → edit one bin script → reinstall → file kept and
reported; with `--overwrite-local` → replaced and backup present.

### PR 3 · 🧪 Turn open field notes into code + regression tests

Each item is one commit with its test. Items already fixed upstream get only the test.

| Field note | State upstream | Work |
|---|---|---|
| Keyword gate trips on SQL literals in tests | **Not fixed**: `merge-policy.py` scans every added line | Add `merge_policy.keyword_exclude` (default `**/tests/**`, `**/test/**`, `**/*.Tests/**`, `**/*Tests.cs`, `**/*.test.*`, `**/*.spec.*`). Paths still count for size. Test: a diff adding `delete from` under `tests/` → no human gate; same line under `src/` → gate. |
| `--paginate --slurp` REST pages for `issues` | Fixed (payload-first) | Add the missing test: REST list-of-pages payload validates; malformed page → exit 64 for agent kind, halt under `SB_GITHUB_READ_STRICT=1`. |
| Migration gate with no reachable DB can never pass | Workflow backend checks `migrations.checks` at start; **headless runner does not** | Port precondition 7 of `run-workflow.md` into `super-board-run.sh`. Also: an env in `allowed_envs` with a command and no check, plus no `commands = "-"` declaration → refuse to start with the config key to fix. |
| Stale `inflight` locks for QA/Review | Fixed (per-tick reap) | Test: dead pid lock on a Review card → lock removed + assignee released + card re-dispatchable next tick. |
| Checkout drifts onto a feature branch | Not handled | Runner precondition: `git branch --show-current` ≠ `base_branch` → refuse to start (exit 73) with the sync command. Autostart runs the sync itself only if the tree is clean. |
| EF migrations per module, dependency order, PostGIS | Product-specific | Not a pack change. Record in the pilot's `CONSTRAINTS.md` / `AGENTS.md`, and make `migrations.commands.<env>` call one ordered script in the pilot repo. |

Also add to the top of `field-notes.md`: *every entry ends with `test: <path>` or
`no-test: <reason>`*. A note with neither is unfinished work.

---

## Phase 2 — Halt and block taxonomy (P0)

### PR 4 · ⏯️ Classified halts with automatic resume for transient reads only

**Why.** Today any required-read failure writes `github-halt.json` and stops the whole run
until someone runs `--resume`. Most such halts in practice are outages or rate limits, and
the existing `--resume` already re-probes the failed read safely.

**Change** in `scripts/super-board-github-read.py`:
- Record `class` in the halt file:
  - `transient_read` — 3 attempts failed on timeout, 5xx, network, or secondary rate limit,
  - `permanent_read` — auth, permission, invalid query (already detected by `permanent_error`),
  - `shape` — validator rejected the payload under strict mode,
  - `uncertain_write` — written via `--halt` after a mutation failure.
  Old halt files without `class` are treated as `permanent_read`.
- New `--auto-resume`: if and only if `class == transient_read`, run the existing `--resume`
  probe. Track `auto_attempts` and `next_probe_at` in the halt file; backoff 2, 5, 10, 20,
  30, 30 minutes; after 6 failures stop trying and append to `needs-attention.log` once.
- Any other class: `--auto-resume` exits non-zero and changes nothing.

**Callers.** Headless runner tick: if halted, call `--auto-resume` instead of exiting; sleep
until `next_probe_at`. Workflow backend: wave loop step 1 does the same before declaring the
run stopped. Remove "Do not schedule automatic retries of the stopped run" from
`run-workflow.md` for `transient_read` only, and say so explicitly.

**Tests** (`tests/test_github_reads.py`): each class recorded correctly; `--auto-resume` on
`uncertain_write`, `permanent_read`, `shape` → no change; transient + probe succeeds →
cleared and archived with original reason; backoff schedule honoured with an injected clock
(`SB_NOW`); 6 failures → exactly one needs-attention line.

### PR 5 · 🧭 Machine-readable block classes and resume conditions

**Why.** The Block template already has reason tags, the mandatory `blocked-by:` line, the
dependency sweep and verified 🙋 `done` resume. What is missing is a way to park **one card**
on a transient condition and bring it back without a person, instead of halting the run or
leaving it in Blocked forever.

**Change.** Two new machine lines at the bottom of every Block comment, next to `blocked-by:`:

```
block-class: human | dependency | transient
resume-when: <condition>
```

Closed vocabulary for `resume-when`, each verified by the sweep against observable state:

| Condition | Verified by | Allowed classes |
|---|---|---|
| `issues-closed:<n,…>` | issue state reads (today's `blocked-by:`) | dependency |
| `human-done` | existing approval verification | human (🙋 only) |
| `provider-available:<lane>` | provider state file (PR 9; until then `usage.sh check`) | transient |
| `ci-rerun:<sha>` | re-run failed checks once, then read `gh pr checks` for that head | transient |
| `after:<iso>` | clock | transient |
| `never` | — | human |

- New reason tag ⚙️ **Infra / transient** (provider down, CI infrastructure failure, a
  card-scoped GitHub read that exited 64, a merge conflict). ⚙️ is the only tag allowed with
  `block-class: transient`. 🔐 💳 🔑 ❓ 🛡 🧑 🎨 must be `human`; 🙋 is `human` +
  `human-done`; ⏳ and dependency waits are `dependency`.
- Merge conflicts do not need Blocked at all: the gate already sends stale/conflicting PRs to
  Ready. Keep that; do not add a class for it.
- `transient` blocks carry `attempts: <n>`. The sweep moves a card back to Ready (or its
  source column) when the condition verifies, incrementing attempts. The **3rd** transient
  block of the same root-cause hash on one card converts it to `human` (🛡, owner: repo owner)
  and writes one needs-attention line.
- Backward compatible: a Block comment without `block-class:` is `human` unless its
  `blocked-by:` lists issues (then `dependency`) — exactly today's behaviour.
- Lanes hitting a card-scoped exit 64 write a ⚙️ block with `resume-when: after:<now+30m>`
  instead of failing the wave.

**Files.** `writing-standard.md` → `block-template.md` → `super-board-deps.sh` (parse) →
`super-board-wave-plan.sh` (sweep output gains `resumeTransient`) → `super-board-run.sh`
(same sweep per tick) → `run.md` / `run-workflow.md` → `tests/test_writing_format.py`,
`tests/test-deps.sh`, `tests/test-wave-plan.sh`.

**Tests.** Human-class card never swept regardless of other lines; a 🔐 block declaring
`transient` is rejected by the format test and treated as human by the parser; transient
card with condition false stays; condition true → swept with comment; third occurrence →
converted to human; legacy comments parse as before.

---

## Phase 3 — Leases and idempotent recovery (P0/P1)

### PR 6 · 💓 Worker leases with heartbeat

**Why.** Liveness is `kill -0 <pid>`. That misses hung workers (alive, doing nothing), and the
workflow backend has no pid at all, so its only crash recovery runs at run start.

**Change.**
- Lease format v2 in `inflight/<issue>` (keep `PID=` first so old readers work):
  `PID= LANE= PHASE=build|qa|review|merge STARTED= HEARTBEAT=<epoch> HEAD=<pr head sha|-> PROVIDER=<name>`.
- Heartbeat with **zero prompt changes**: when `SB_LEASE_FILE` is set,
  `super-board-github-read.py --check` (already called before every write, merge and
  dispatch) rewrites `HEARTBEAT=` atomically. The runner exports `SB_LEASE_FILE` when it
  spawns a worker; the workflow launcher passes it in the lane args.
- Reap rules: pid dead → reap (today). Pid alive and heartbeat older than
  `lease_ttl_seconds` (default 2700) → needs-attention line once; older than 2× → treat as
  hung: SIGTERM, preserve worktree, release claim, card stays in its column with a comment.
- Workflow backend: one lease per claimed card (no pid). The per-wave reconcile (PR 8) reaps
  leases with stale heartbeats, which gives that backend mid-run crash recovery.

**Tests.** Heartbeat written by `--check` only when `SB_LEASE_FILE` is set; v1 lock still
parsed; stale heartbeat + live pid → attention, then kill at 2× (fake pid via `sleep`);
dead pid → existing reap path unchanged.

### PR 7 · ♻️ Reuse a finished review instead of repeating it

**Why.** If the Reviewer approves and then dies before merging, today the next dispatch runs
the whole review again — the most expensive lane.

**Change.**
- Reviewer verdict comment gains machine lines (writing standard first):
  `review-verdict: approve|bounce|block` and `reviewed-head: <full sha>`.
- Recovery decision for a Review card with no live lease, made by script:
  1. PR merged (read-only `gh pr view --json mergedAt,mergeCommit`) → verify the merge
     commit is an ancestor of base, move to Done, comment. No merge attempt.
  2. Not merged, latest verdict `approve`, `reviewed-head` == current PR head → dispatch
     `PHASE=merge` only: run `super-board-merge-gate.sh --expect-head <reviewed-head>`.
  3. Head moved, no verdict, or verdict not `approve` → full review (today).
- Merge outcome unknown (gate exited mid-merge) → step 1's read decides; never call merge
  twice without that read.

**Tests.** Fixture PR states for each branch above, including "merged but card in Review" and
"approved but head changed" → full review.

---

## Phase 4 — One reconcile contract (P1)

### PR 8 · 🔁 `super-board-reconcile.py`: the single recovery contract

**Why.** Recovery logic is split: bash functions in the headless runner (reap, zombie sweep,
stranded Building, closed-issue reconcile) and ~200 lines of prose the orchestrator LLM
executes every wave in `run-workflow.md` (sweep, resume, refreshApproval, stranded, claim
verify, release, manifest, throttle). The prose path costs tokens every wave and is where
the orchestrator makes mistakes.

**Change.**
- New `scripts/super-board-reconcile.py --config <cfg> [--apply]`. Inputs: board snapshot
  (`super-board-card.sh items`), leases, halt file, provider state, planner output
  (`super-board-wave-plan.sh` stays as its library). Output JSON:
  `{dispatch:[{issue,lane,phase,provider}], recover:[…], resume:[…], sweep:[…], escalate:[…], noop_reason}`.
- `--apply` performs only the safe mutations already allowed by `run.md` (column moves,
  claim and release with verify, standard comments, manifest lines, throttle step-down).
  Dispatch itself stays with the caller.
- Headless runner: each tick calls `reconcile --apply`, then dispatches its `dispatch` list.
  The old helper functions move into the script or become thin wrappers.
- Workflow backend: wave loop becomes `reconcile --apply` → launch wave with `dispatch` →
  on completion `reconcile --apply` again → report from `escalate`. Rewrite steps 2, 3 and 5
  of `run-workflow.md` to that.

**Invariants (each a test).**
- Idempotent: two `--apply` runs on the same snapshot; the second performs zero writes.
- Never dispatches an issue with a live lease or a non-bot assignee.
- Never moves a `human` block card; never touches `uncertain_write` halts.
- With any halt present it only reports, except the `transient_read` auto-resume path.
- Crash between two mutations → next run converges to the same end state (simulate by
  failing the stub `gh` after N writes).

**Done when.** The orchestrator's per-wave work is three tool calls (reconcile, launch,
reconcile) and the metrics from PR 0 show no rise in wasted dispatches.

---

## Phase 5 — Provider scheduler (P1)

### PR 9 · 🔀 Health-aware provider state

**Why.** Field notes: both vendors ran dry together; a fixed TTL (5 h, now 30 min) either
strands cards or re-hits the limit; Claude/Codex usage often reads `unknown`; Codex is
treated as always available.

**Change.** `scripts/super-board-providers.py` owns
`.claude/super-board/providers/<name>.json`:
`{state: ok|paused|probing|open, paused_until, reason, consecutive_failures, last_success, probe_interval}`.

| Signal | Action |
|---|---|
| Claude usage guard `pause` | `paused_until = resets_at + 60s` (known exactly from `usage.sh`) |
| Vendor limit error with a reset time in the text | Parse it; `paused_until` = that time |
| Vendor limit error, no reset time | `probing`: allow **one** card on that provider after 15 min; success → `ok`; failure → double the interval, cap 60 min |
| Usage `unknown` | Not exhausted. Dispatch normally; rely on error signals |
| 3 consecutive non-quota failures (no result, crash) | `open` for 30 min + one needs-attention line |
| Every lane provider paused/open | One alert, sleep until the earliest `paused_until`/probe time; no GraphQL ticks meanwhile |

- **Two thresholds instead of a reservation system:** `usage.build_pause_pct` (default 85)
  and `usage.review_pause_pct` (default 95). New Build work stops first so cards already in
  QA/Review can finish within the window.
- Reset-time patterns live in a data table (`providers/patterns.json`) built **only from real
  error lines copied out of the pilot's worker logs**. Do not invent formats; an unmatched
  limit error falls back to probing.
- Metered providers stay out of lane order by default (orchestrator budget rule unchanged).
- No attempt to evade provider limits.

**Tests.** Injected clock; fixture error strings; probe allows exactly one dispatch; circuit
opens and closes; all-paused computes the right wake time; reconcile (PR 8) consumes the
state and assigns `provider` per dispatch.

---

## Phase 6 — Grooming (P1)

### PR 10 · 🎫 Readiness certificates and event-driven grooming

**Why.** A groom agent re-reads and re-grooms unchanged stories.

**Change.**
- After a story passes groom/lint, write a hidden marker comment:
  `<!-- sb-ready v1 hash=<sha256(title+body+labels)[:12]> checks=ac,deps,scope,risk -->`.
- `scripts/super-board-groom-select.py` (deterministic) returns only Backlog issues that
  have no certificate or whose current hash differs. Runs only when `Ready <= ready_floor`
  or the backlog signature changed, and the cooldown has passed. The groom agent receives
  that list, never the whole backlog. Empty list → no agent call.
- Unchanged guardrail: open scope question → story skipped, question recorded, owner asked.

**Tests.** Unchanged certified issue not selected; body edit → selected; no trigger → no call.

---

## Phase 7 — Later, only if the metrics justify it (P2)

- **Improvement proposals, not self-modification.** A weekly scheduled task clusters
  `interventions.jsonl` + `needs-attention.log` by class. A class seen ≥ 3 times gets a
  **draft PR** with a failing test fixture and a proposed fix for the owner to review. It
  never merges itself and never touches hooks, guard scripts, merge policy, approval logic,
  halt semantics or permissions.
- **Adaptive model routing** by outcome: wait until ≥ 100 Done cards with per-card provider,
  model, attempts and bounce data exist.

## Out of scope on purpose

- A separate always-on controller daemon next to the runner: PR 8 evolves the existing
  runner instead of adding a second loop that could disagree with it.
- Letting agents resolve product scope, auth/trust changes, destructive data or public
  contract breaks. `decision-policy.md` and `design-preflight.md` already draw this line well.
- Delegating control-plane fixes to the board's lanes (owner rule in `orchestrator.md`).

## Success criteria for the whole plan

Measured with PR 0 over the same kind of pilot workload, before vs after:

- interventions per 100 Done cards down by at least 70 %,
- zero whole-run stops caused by `transient_read` halts or a single card's read,
- zero repeated full reviews of an already-approved, unchanged head,
- median non-human Blocked time under 1 hour,
- no new merges without the existing gate, approvals and ancestry check.
