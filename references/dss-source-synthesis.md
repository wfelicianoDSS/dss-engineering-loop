# Source Synthesis — what the loop takes from where

Four sources. This file records what each contributes, what is deliberately left
behind, and where the spec's section numbers map. It exists so a later reader can
tell an inherited decision from an invented one.

| Source | License | Role in the loop |
|---|---|---|
| **super-board** (EricTechPro) | MIT | The **engine**. Board-driven execution, dependency resolution, stage lifecycle, merge gate, Codex fallback lanes. This fork's base. |
| **pstack** (cursor/plugins) | — | The **autonomy discipline**. When a loop may run unattended, how to hand off between agents, how to audit a run afterwards. |
| **agent-skills** (Addy Osmani) | MIT | The **portability pattern** and per-stage playbooks. One skill set, thin per-agent adapters. |
| **fieldops-story-workflow** (DSS) | — | The **security and verification bar**. Tenant invariants, timestamp precision, review-before-commit, scope discipline. |

---

## 1. super-board — the engine

### Taken

**Board-driven execution.** The centerpiece: an agent reads the GitHub Project,
picks an eligible card, and drives it through gated stages. This is what removes
William from the loop, and it is why the fork exists.

**`scripts/super-board-deps.sh` — the dependency primitive.** Parses
`## Blocked by` from the issue body and `blocked-by:` from Block comments, and is
**fail-safe, not fail-open**: an issue it cannot parse confidently is reported
`parseable: false` and callers must treat it as *blocked*. Guessing "runnable" on
an ambiguous line is how a card gets built against a base that lacks its
dependency. The script's header documents three real misparses observed on a live
board (a banner quoting the heading; a line saying "None — but #26 must merge
first"; an empty section). Do not reimplement this naively.

**The stage lifecycle.** `build → qa → review` per card, with statuses
`advanced | bounced | blocked | human-gate | failed | halted`. This *is* the spec's
§4 state machine, already implemented and debugged. `human-gate` is `Awaiting PO`.

**Builder pre-flight.** Per Ready card: already done? in progress? file overlap?
unclear? Prevents two lanes colliding and prevents redoing finished work.

**`merge_policy.always_human`.** Label / path-glob / keyword categories that force
a human merge, matched against the diff's **added lines only**. This is the spec's
§18 risk router and §21 merge policy as config rather than code. FieldOps maps its
CRITICAL tier onto it in `profiles/fieldops.json`.

**The merge gate, and why the check is inside the lock.** From the script's own
header, measured on 2026-08-20: PR #89 read `MERGEABLE`/`CLEAN` from GitHub and
still failed `tsc` against current `staging`, because a PR merged after #89 was
tested had added a member to a shared interface. Eleven test files git-merged
without one conflict marker and stopped typechecking. GitHub answers "does the
text conflict?", not "does this still compile against the base it lands on."
A check *before* the mutex proves the branch good against a base another lane may
replace while it waits — the same stale-approval shape one level down. Cost: one
serialized verification per merge. Alternative: a red base branch.

**`scripts/super-board-codex-lane.sh` — the authority constraint.** A usage-fallback
agent **may build and QA but never owns Review or merge** (exit 78 if it tries).
This is the spec's §2.2 "automate execution, not authority", already enforced in
code, and it is the answer to "when Claude usage runs out, Codex continues."

### Left behind

- The `claude-p` legacy headless dispatcher (superseded by the workflow backend).
- Upstream's default `always_human` set (replaced wholesale by the FieldOps
  categories — note that setting the key replaces, not merges).

---

## 2. pstack — the autonomy discipline

### Taken

**The four preconditions for leaving a loop unattended.** Verbatim, because they
are the gate on this whole project:

> - You've done the task once by hand, or watched an agent do it, so you know what good looks like.
> - The agent has the tools and signals you'd use yourself.
> - Every stage proves its work and can stop the line when the work misses the bar.
> - You've read a few transcripts and turned the repeated failures into tools, skills, or checks.
>
> "A loop you don't trust just produces unchecked work faster, and the mess compounds with every iteration."

FieldOps currently passes 1–3 and **fails 4** — US-095 produced two defects of the
same class (a server change altering a taxonomy a client interprets) that two
review rounds missed. `dss-cross-surface-contract.md` is the conversion of that
class into a check. Autonomy should rise when precondition 4 holds, not before.

**`pause-safely` → the cross-agent handoff primitive.** This is how work survives
an agent swap, and it needs no new infrastructure:

1. Stop at a safe boundary; finish or back out the current atomic step; cancel nested subagents.
2. Take no irreversible action to pause (no PR, no push, unless one already exists).
3. Commit uncommitted edits as one `wip:` commit so nothing is lost. If the tree is broken, say so in the commit body.
4. Write a resume note off-context: intent, what you were doing, progress and what is verified, current state, next steps, key files, gotchas.

A cold-start agent — any vendor — resumes from the `wip:` commit plus the note.
**This is the agent-agnostic continuity answer**; the board holds workflow state,
the resume note holds in-flight state.

**The overnight contract.** A handoff needs goal, finish condition, permissions,
escape hatch. The escape hatch matters most: *stop at a genuine dead end and write
up why*, which beats hours of creative goal reinterpretation.

**The decision log + morning audit.** One row per decision — time, phase,
decision, reason, evidence pointer, result. The audit reads the trail, not the
whole transcript, and surfaces an *Attention* section first. Adopt when a run
grows past what a PR diff can convey.

**One change → one check → one log row, per iteration.** Changes that did not help
are **discarded, not left to ride**. A plateau means pivot, not quietly relaxing
the finish condition.

**Principles as steering names.** 24 named rules the agent has already read, so one
phrase redirects work precisely ("use subtract before you add", "apply prove it
works"). The enforcement detail is what makes it work: **the agent must name which
decision the principle changed.** A citation with no decision behind it is the tell
that it name-dropped instead of applying. Several map onto existing DSS rules —
`prove it works` (§2.4), `fix root causes` (bug playbook), `make operations
idempotent` (retry contract), `separate before serializing shared state` (§2.6),
`model the domain` (§5), `type system discipline` and `boundary discipline` (§2.8's
"fix at the highest effective level").

**`build the lever`.** When an agent keeps doing something by hand, have it write
the tool or skill it wished it had. If a script can do a step identically every
time, use the script and save agents for judgment. This is §2.8's mechanism.

### Left behind for now

- `autopilot-full` (queue of independent PRs to merged) — Level 5, not yet.
- `arena` (multi-model competition per task) — the spec's §37 defers it, correctly.

---

## 3. agent-skills — portability and playbooks

### Taken

**The adapter pattern — the agent-agnostic answer.** Skills are written **once** as
Markdown; thin per-agent adapters point at them:

```
skills/<name>/SKILL.md      <- engineering logic, written ONCE
.claude-plugin/plugin.json  <- Claude
.codex-plugin/plugin.json   <- Codex   ("skills": "./skills/")
.gemini/commands/*.toml     <- Gemini
.opencode/ .agents/         <- others
```

Each adapter is ~20 lines: "invoke skill X", plus that agent's mechanics. Gemini's
`ship.toml` explains how *Gemini* spawns subagents (files in `agents/` become
callable tools); the Claude adapter says the same thing in Claude's idiom. **The
engineering logic never forks.** FieldOps' `.codex/skills/fieldops-story-workflow`
is already 90% of this shape — plain Markdown, no vendor-specific tool calls.

**Executable validators over prose.** `scripts/` holds `validate-skills.js`,
`validate-commands.js`, `validate-reference-links.js`, `floor-guard-reference-test.js`
— each with its own test. The skill set validates itself in CI. This is §2.8 applied
to the workflow repo, not just the product.

**Evals for skills** (`evals/cases`, `evals/fixtures`). The workflow is treated as
software with regression tests. Relevant once DSS skills are reused across projects.

**Stage playbooks worth lifting** (where DSS has no equivalent):
`spec-driven-development`, `planning-and-task-breakdown` (vertical slices, not
horizontal layers), `incremental-implementation`, `observability-and-instrumentation`,
`deprecation-and-migration`, `context-engineering`.

**Already covered under other names** — adopt the *name*, not a second copy:
`doubt-driven-development` → spec §20; `constraint-driven-development` → §10/§11;
`code-review-and-quality` → §19; `source-driven-development` → §14;
`documentation-and-adrs` → §29; `test-driven-development` → the DSS `/tdd` pipeline.

### Left behind

- `frontend-ui-engineering`, `browser-testing-with-devtools` — DSS already has
  `frontend-design` + the design loop + playwright.cli.

---

## 4. fieldops-story-workflow — the bar

### Taken (non-negotiable; overrides any source above)

**The security invariants.** 401 unauthenticated / 404 missing org / 403 missing
membership / 403 missing permission / 409 inactive org / 404 missing tenant
resource / **the same 404 for a foreign tenant resource**. Tenant ownership
enforced at the **database query boundary**; trusted source is
`ICurrentOrganization.OrganizationId`; client-supplied organization IDs never
authoritative. Never load a tenant-owned resource by ID and check tenancy in memory.

**Review the actual diff before committing.** Do not approve from an
implementation report. US-095 is the proof: the implementation report read clean,
and reviewing the staged diff found two blockers.

**The implementer is never the sole reviewer.** Fresh-context reviewer on the
staged diff, with a correction loop that sends back *only* the specific defect and
prohibits unrelated cleanup.

**PostgreSQL timestamp precision.** `timestamp with time zone` stores whole
microseconds; .NET `DateTimeOffset` carries 100-ns ticks. Any test comparing an
in-memory timestamp created *before* persistence against a value read back must use
`PostgreSqlTimestampAssertions.EqualToPersisted`. CI's guard catches only newly
added **one-line** `Assert.Equal` with timestamp-like names — multiline and other
assertion forms need manual provenance review, and affected tests run in **Release**
before shipping. This has repeatedly failed CI.

**Scope discipline.** No speculative repositories/interfaces/factories/services/
config/extension points. No future-story work. Prefer existing repository patterns.
When uncertain whether something belongs, defer and surface it — now governed by
`dss-deferral-rule.md`.

**Ponytail during implementation only, never for product architecture.** FieldOps
security, correctness, testing and approved requirements override Ponytail
minimization. Never `ponytail ultra` for FieldOps stories.

**The final verification gate.** Focused tests while iterating; then full unit,
full integration once, Debug build, Release build, EF pending-model check when
persistence is involved, `git diff --check`.

---

## 5. DSS originals — not from any source

**Quality-bar integrity review** (spec §12). Reviewers inspect attempts to weaken
the verification system itself: removed or skipped tests, weakened assertions, new
suppressions, lowered thresholds, disabled analyzers, deleted CI steps, work hidden
behind TODOs. *The implementation must satisfy the bar; the bar must not move to
satisfy the implementation.* No equivalent found in any of the three repos.

**Cross-surface contract invariant** (`dss-cross-surface-contract.md`). Derived from
US-095's silent-data-loss defects. No source covers it: the FieldOps workflow
guards tenant/auth/lifecycle but not client-contract drift; super-board guards
merge-time base drift; pstack's `prove it works` would catch it on a device but not
by reading; agent-skills has review rubrics but nothing cross-surface.

**Deferral rule** (`dss-deferral-rule.md`). The causal test — *did this become wrong
because of the change in flight?* — distinguishes in-scope collateral from genuine
pre-existing debt.

**Risk-tiered curation contract.** The spec's §5 lists 13 sections; US-095 had four
genuinely load-bearing decisions. A template that is 70% "n/a" trains agents *and
William* to skim it. Tier the contract by §18 risk instead: LOW/MEDIUM gets outcome
+ behavior + acceptance + exclusions; HIGH adds authorization, tenant, lifecycle,
persistence, idempotency; CRITICAL adds security, blast radius, observability,
destructive-behavior review.
