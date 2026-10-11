# Deferral Rule

**Applies to every agent at every stage: Builder, QA, Reviewer, Orchestrator.**

## The rule

> Before deferring any finding, answer one question:
>
> **Did this become wrong because of the change in flight?**
>
> - **Yes → it is in scope.** Fix it now. Pre-existing code that your change made
>   incorrect is *your change's defect*. "It was already there" is false when the
>   thing that broke it is in your diff.
>
> - **No → defer, but the deferral is only approved once the tracked issue exists.**
>   The issue URL goes in the PR body. **No issue, no deferral** — without one the
>   work stays in the story.

## Design-friction escalation

Three deferrals to the same file or subsystem within one story is a **design
signal**, not three issues. Stop and surface it: the abstraction is probably
wrong, and filing three tickets hides that.

## Why this exists — the incident it comes from

During US-095, `resolveFailedEvidenceCaptures` was flagged as kind-blind: a
confirmed *After* photo marked a failed *Before* photo as `replaced`, hiding a
genuinely lost photo from the operator.

The reviewer classified it NON-BLOCKING and "pre-existing, untouched by this
diff". The orchestrator deferred it on that basis. **That was wrong.**

The query predicated on `workItemId + createdAt` with no `kind`. That was
*correct* while only one evidence kind existed. US-095 is the story that added
the second kind — so US-095 is the story that broke it. It was in-scope
collateral, and William caught it by reading the code after review had passed.

The "pre-existing" label was accurate about the code's *age* and misleading about
its *correctness*. The question that resolves it is not "was this line in the
diff?" but "does this line still do the right thing after my change?"

## Both tests applied to US-095

| Finding | Became wrong because of this change? | Verdict |
|---|---|---|
| `resolveFailedEvidenceCaptures` is kind-blind | Yes — this story added the second kind | **In scope.** Fixed. |
| Sync classifier misses the permanent `409` | Yes — this story created the first permanent 409 on capture | **In scope.** Fixed. |
| `evidence_object_size_mismatch` retries forever | No — pre-existing on the confirm path, unchanged by this story | **Deferred** → needs a tracked issue |
| Detail endpoint exposes no after-evidence state | No — the gate is new, but the endpoint's silence predates it | **Deferred** → needs a tracked issue |

The first two were initially deferred and should not have been. The rule exists
so the next agent asks the right question the first time.

## Interaction with scope discipline

This does **not** license scope creep. The FieldOps scope guard still holds: do
not pull later stories forward, do not refactor adjacent code, do not fix
unrelated defects you happen to notice.

The distinction is causal, not proximate:

- **In scope:** code your change made incorrect.
- **Out of scope:** code that was already incorrect and stays exactly as incorrect
  as it was.

A defect you *created* is not scope creep to fix — it is the story being
unfinished.
