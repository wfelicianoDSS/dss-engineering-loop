# Definition of done

A card is **Done** only when every line below is true **and** the merge landed on the
base branch. The run loop's landed-work halt gate reads `Done` as its definition of
progress, so a card marked Done without a confirmed merge makes a runaway look healthy.

- [ ] Acceptance criteria pass, each with a checkable test (not a self-report).
- [ ] Tests are committed and green; the Reviewer re-ran the exact `Local tests:` command.
- [ ] The PR is under `merge_policy.auto_max_lines`, or a documented split is filed.
- [ ] No unresolved `[builder]` / `[qa]` / `[reviewer]` threads.
- [ ] Adversarial truth-check ≥ `config.truth_threshold` (when `truth_gate` fires).
- [ ] `security-checklist.md` passed.
- [ ] Migrations: allowed envs applied; live DB / money / auth / destructive schema → 🙋 human.
- [ ] The merge commit is confirmed an ancestor of the base branch (`git merge-base --is-ancestor`).

Anything not checkable here is not a Done card; it is a finding, a human gate, or a split.
