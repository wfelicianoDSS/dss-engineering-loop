# Engineering principles

Read these at task start. Each is one rule; the inline note says how to apply it.
Distilled from the pstack principle set for a board whose cards are small, verifiable
vertical slices. Every lane agent reads this file once before working; it is a checklist
of judgments, not extra process.

| # | Principle | Rule and how to apply it |
|---|---|---|
| 1 | Laziness protocol | Bias to deletion and the smallest change that solves the problem. Delete before you add. |
| 2 | Foundational thinking | Choose the core types and data shape before the logic. Get the domain model right and the endpoints become obvious. |
| 3 | Model the domain | Encode the domain in a structure (enum, `Result<T>`, a typed record) instead of scattered conditionals. |
| 4 | Sequence verifiable units | Break work into small units that each end in a verifiable state; check each before the next; one commit per accepted unit. |
| 5 | Prove it works | Verify against the real artifact — run the feature, read the actual value, inspect the diff — never a self-report or "it compiles". |
| 6 | Test behavior, not implementation | Call the code the way its users do and assert the observed result against a literal expected value. If the test would still pass after deleting the code, rewrite it. |
| 7 | Fix root causes | Reproduce first, ask why until you reach the root, and fix it there. Resist guards that only silence a crash. |
| 8 | Build the lever | For a repetitive change, build the script or generator that does it, so a reviewer can rerun it. |
| 9 | Encode lessons in structure | Turn a learned rule into a lint, runtime check, migration, or guard — not more prose. |
| 10 | Minimize reader load | Collapse one-caller wrappers, shrink mutable scope, keep the path from question to answer short. |
| 11 | Attack the premise | When two fixes for the same symptom both fail, question the premise instead of writing a third fix that assumes it. |
| 12 | Never block on the human | Proceed, present the result, and let the human course-correct after; reserve a stop for irreversible actions (money, auth, destructive schema, live DB). |

The lanes map these to their own gates: the Builder uses #1–#6 inside red-green-refactor;
the Reviewer uses #5, #6, #11 in its adversarial pass; both obey #12 against
`merge_policy.always_human` and the `human-gated` label.
