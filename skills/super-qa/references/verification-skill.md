# Project-local verification skill

Tests answer "does the code do what I built?". A verification skill answers the other
question — "does the **app**, driven the way a user drives it, actually behave?" — by
launching it, exercising a feature the way a user would, and capturing evidence.

Generate it once as a project-local skill at `.claude/skills/verify-<app>/`; every lane
(Tester first) then uses it instead of re-inventing launch/drive steps. Adapted from
pstack's `create-verification-skill`.

## 1. Interview the repo, not the user

Answer from the codebase; only ask what you cannot observe:

- **Surface** — what does a user touch? Web UI, CLI/TUI, desktop app, API, mobile app,
  library. A repo can have several; pick the primary and note the rest.
- **Run** — how does the app start locally? Prefer the repo's own documented dev command
  (package scripts, Makefile, README quickstart). Note ports, env vars, seed data, auth.
- **Drive** — how can an agent interact programmatically? Existing harnesses first
  (Playwright/Cypress specs, HTTP endpoints, a debug port); only then a generic recipe
  (browser/CDP for web, a PTY/tmux harness for CLI, plain HTTP for services).
- **Observe** — what evidence can be captured? Screenshots, transcripts, response bodies,
  logs, exit codes, DB state.
- **Isolate** — can two instances run side by side (ports, data dirs)? If not, say so in
  the skill: refusing to double-drive a shared instance beats corrupting the user's.

If the checkout doesn't build or start as-is, fix or report that first — a skill written
against a broken base teaches wrong steps.

## 2. Generate the skill

Write `.claude/skills/verify-<app>/SKILL.md` with frontmatter (`name: verify-<app>` and a
description naming the app, the surface, and when to reach for it) and these sections,
each grounded in what the interview found — no placeholders left:

- **Launch** — the exact command that starts the app, and how to tell it's ready (a log
  line, a prompt). Ready means usable, not just that a process answers. Include teardown.
- **Doctor** — one read-only check answering "is this instance worth driving?": process
  up, right build/version, port owned by us, auth valid.
- **Drive** — the harness recipe with real selectors/commands from this repo. Prefer
  stable handles (ARIA labels, data attributes, route paths) over coordinates/tab order.
- **Evidence** — what to capture and where. Proof standards: exercise the real user path
  (not internal setters or test-only endpoints); capture the action *and* the resulting
  state; verify side effects (files written, rows inserted) alongside what's visible.
- **Cleanup** — tear down instances the run created; never kill by process name, kill what
  you started. Cleanup removes instances and scratch state, **never the evidence**.
- **Helpers** — any shipped script is executable and its invocation is shown in the body.

## 3. Seed the feature map

Create `.claude/skills/verify-<app>/features/README.md` plus one file per user-facing
feature (aim for the top 3–5, from routes, commands, menus, or docs). Each file answers,
from the user's point of view: what the feature is, how to reach it, how to drive it with
the harness, and what observable end state proves it works. Four H2s: `Sub-features`,
`How to get to it (user POV)`, `Driving it with <harness>`, `Gotchas`.

Never weaken a journey to make it pass; a missing precondition is a failure with a reason
in that feature's `Gotchas`.

## 4. Prove the generated skill before handing it over

Run its own instructions end to end once: launch → doctor → drive ONE mapped feature →
capture evidence → clean up. After cleanup, confirm the evidence still exists — a cleanup
that eats the proof fails the step. Fix what fails. A generated skill that was never
executed is a draft, not a deliverable.

## 5. Keep it honest (maintenance)

When the app changes, update the map (a source pass plus one live pass; at most one PR of
proven corrections). The Tester lane re-checks the map on any UI-affecting card.

## How the Tester uses it

- **Exists** → drive the affected feature through it for evidence; save evidence to the
  card's `docs/super-board/runs/issue-<N>-qa-v<V>/` dir and embed it per run.md.
- **Missing + UI-affecting card** → create it once per project (sections above), then use
  it. Once per project, never per card.
