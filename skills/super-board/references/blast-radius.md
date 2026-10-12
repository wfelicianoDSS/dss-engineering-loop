# Blast radius

A small-looking change can still break something far away. Before building or approving,
name what else this touches, and prove the safety with running code — not an assertion.
The Builder runs this in pre-flight; the Reviewer checks the named fact.

## Before a build

1. **Find the callers.** Grep every caller of the function, type, or endpoint you change
   (`git grep -n`, IDE find-usages). Count them. A change to a shared helper is not local.
2. **Find the shared state.** Does this change a type, an EF configuration, a migration
   *snapshot*, an interface, or a shared enum that other modules read? A changed EF context
   or migration snapshot can collide with **any open card** touching the same context —
   sequence the cards (the super-board pre-flight already sequences overlapping cards; this
   is the manual cross-check when two lanes race).
3. **Find the invariants.** Which guarantee does this change rely on or alter — tenant
   scoping, money, authorization, lifecycle? Those are human gates, not lane decisions.

## What to report

Add one **Blast radius** line to the PR body / build report:

- the callers touched (count),
- the shared files changed (EF context / migration snapshot / interface),
- the single fact the change is safe **because of** — proven by a command.

## The one fact

The safety claim must name the artifact that proves it:

- "safe because the only caller is `X` (`git grep` → 1 hit) and its test is green";
- "safe because the migration is additive (`Up` only adds a column)";
- "safe because tenant scoping is unchanged (`organizationId` predicate still in the one
  query — see `…Endpoint.cs:57`)."

If you cannot name the artifact, it is not safe to merge — say so and let the Reviewer or
a human decide.
