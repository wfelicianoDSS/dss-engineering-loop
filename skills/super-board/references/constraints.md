# Constraint-driven development

A written quality bar the whole project shares, so a lane does not invent its own bar — or
quietly lower it to get green. The human writes it once as `CONSTRAINTS.md` at the repo
root; every lane reads it before working and no lane edits it.

## What it is

`CONSTRAINTS.md` lists the checks that must hold for **any** change — builds, tests, lint,
type-check, tenant isolation, no secret literals — each with the **cheapest layer that can
enforce it** and the exact command. It is the standing definition-of-done for the repo;
per-card acceptance criteria are separate and live on the card.

## Place each check at its cheapest layer

A rule that can be enforced by an earlier layer should be moved there and the prose
deleted — prose is the layer nobody runs.

1. **Type / domain model** — make the wrong state unrepresentable. A non-nullable `Reason`
   on `Kind.Additional` beats a paragraph asking people to set it.
2. **Lint / analyzer** — a rule the compiler or linter enforces on every edit.
3. **Runtime check at the boundary** — validation where external input enters.
4. **Test** — the behavior a test asserts.
5. **Docs** — last resort; text nobody runs.

## Anti-rationalization (no lane may)

- disable or weaken a check to make it pass;
- `skip` a test to get green, or loosen an assertion;
- add an exclusion from a lint/build without a written reason;
- widen `merge_policy.size_exclude` to dodge the size cap.

A failing check is a **finding**, not an obstacle. Relaxing a rule is a human decision
recorded once in `CONSTRAINTS.md`, never a lane-local edit.

## Template

`super-board onboard` scaffolds this when the file is absent; keep it short and runnable.

```markdown
# CONSTRAINTS.md — <project> quality bar

| Constraint | Cheapest layer | Command |
|---|---|---|
| Builds clean | build | `dotnet build FieldOps.slnx -c Release` |
| Unit tests green | test | `dotnet test tests/FieldOps.UnitTests -c Release` |
| Tenant isolation holds | integration test | `dotnet test --filter FullyQualifiedName~WorkManagement` |
| No secret literals | guard hook | `.claude/hooks/guard-key-literals.py` |
| Mobile typecheck + tests | lint | `cd mobile && npm run check` |

Relaxations (human-approved only):
- (none)
```
