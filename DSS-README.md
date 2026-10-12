# DSS Engineering Loop

A fork of [super-board](https://github.com/EricTechPro/super-board) (MIT) adapted
as Digital Stack Solutions' software-development operating system: an agent reads
the GitHub backlog, picks an eligible story, and drives it through gated stages,
with human authority preserved where it matters.

Synthesizes four sources — see [`references/dss-source-synthesis.md`](references/dss-source-synthesis.md)
for what each contributes and what was deliberately left behind:

- **super-board** — the engine (board-driven execution, dependency resolution, stage lifecycle, merge gate, Codex fallback lanes)
- **pstack** — the autonomy discipline (unattended-run preconditions, cross-agent handoff, decision log)
- **agent-skills** (Addy Osmani) — the portability pattern (one skill set, thin per-agent adapters) and stage playbooks
- **fieldops-story-workflow** (DSS) — the security and verification bar

## Why a fork, and how it stays mergeable

Upstream is actively developed (it committed the day this fork was taken), so
**every DSS addition lives in a new file**. `scripts/`, `workflows/`, and
`skills/super-*` are left untouched, so `git merge upstream/main` stays clean.

```bash
git remote -v
# origin    git@github-dss:wfelicianoDSS/dss-engineering-loop.git
# upstream  https://github.com/EricTechPro/super-board.git

git fetch upstream && git merge upstream/main
```

DSS files, all new:

```
DSS-README.md
profiles/fieldops.json
references/dss-source-synthesis.md
references/dss-cross-surface-contract.md
references/dss-deferral-rule.md
```

## Core design decisions

**Automate execution, not authority.** The loop may become highly autonomous at
executing. It stays conservative about *deciding*. Upstream already enforces the
key case in code: a usage-fallback agent (Codex) may build and QA but **never owns
Review or merge** (`scripts/super-board-codex-lane.sh`, exit 78). That is also the
answer to "when Claude usage runs out, another agent continues" — execution is
portable, authority is not.

**The board is durable state.** Workflow progress lives in the GitHub Project, not
in chat or agent memory. In-flight state lives in a `wip:` commit plus a resume
note (pstack's `pause-safely`). Any agent, any vendor, resumes from those two
things.

**Fail safe, not fail open.** A story whose `## Blocked by` section cannot be
parsed confidently is treated as **blocked**, never runnable. Guessing "runnable"
is how a card gets built against a base that lacks its dependency.

**Risk decides review depth.** `merge_policy.always_human` in the profile routes
any PR touching tenant isolation, authorization, migrations, lifecycle, money, or
evidence storage to a human merge — matched on labels, path globs, and keywords in
the diff's *added lines*. Documentation changes still merge on a clean review.

## Dependencies: the `## Blocked by` contract

Every story issue carries a section the dependency resolver reads:

```markdown
## Blocked by

- #212
- #213
```

Write `None` **only** when nothing blocks the story. A line that says `None` *and*
names an issue is treated as unparseable → blocked, because that ambiguity has
caused real misbuilds upstream. Put genuine blockers on their own lines.

## Setup

1. ~~Fill in `project.number`~~ — done: project **1**, "FieldOps Development" (`PVT_kwHOD92re84BjenL`). Needs the `project` scope: `gh auth refresh -s project`.
2. **Add the four missing Status options** (see below) — `/super-board onboard` does this and keeps every card.
3. Copy the profile into the fieldops repo as `.claude/super-board/configs/fieldops.json` (strip `//` comments).
4. Run `/super-board onboard` in the fieldops repo to install guard hooks, `.claude/bin` scripts, and workflows.
5. Add `## Blocked by` sections to the active epic's stories.

### Status column gap — blocks step 4

The board currently carries GitHub's default five options:

```
Backlog, Ready, In progress, In review, Done
```

The engine needs seven:

```
Backlog, Ready, Building, QA, Review, Blocked, Done
```

`In progress` → `Building` and `In review` → `Review` are tolerated as aliases and
canonicalized at read time, but **`QA` and `Blocked` do not exist at all**.

`Blocked` is not optional for FieldOps: it is where the merge gate parks every PR
that trips an `always_human` category (tenant, authz, migrations, lifecycle, money,
evidence) — which is most FieldOps work. Without that column the risk router has
nowhere to put a card, and `human-gate` has no destination.

The board also carries DSS fields the engine does not read but which stay useful
for curation: `Work Type` (Epic/Feature/User Story/Task/Bug), `Area`, `EPIC`,
`Feature`, `Priority`, `Size`. Note the engine routes on the three repo **labels**
(`qa`, `bug`, `feature`), not on `Work Type` — a story needs the label, not just
the field.

## Autonomy maturity — where FieldOps actually is

pstack gates unattended runs behind four preconditions:

1. You know what good looks like — **pass**
2. The agent has the tools and signals you'd use — **pass**
3. Every stage proves its work and can stop the line — **pass**
4. Repeated failures have been turned into tools, skills, or checks — **FAIL**

US-095 produced two defects of the same class (a server change altered a taxonomy
a client interprets; neither was caught by two independent review rounds).
`references/dss-cross-surface-contract.md` converts that class into a check.

**Raise autonomy when precondition 4 holds, on evidence, not on tooling capability.**
Start at Level 2 (Ready cards flow through Build → QA → Review automatically,
human merges). Do not jump to auto-merge because the config allows it.

## Deliberately not built yet

Feedback collectors (Sentry/PostHog intake), the retro watcher, the executable
feature map / Working Software Gate, bounded self-repair, and unrestricted
auto-merge. Each is Level 3+ and unrelated to board-driven execution. Add one when
a specific failure demands it.
