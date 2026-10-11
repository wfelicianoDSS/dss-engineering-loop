# Cross-Surface Contract Invariant

**Required at Curation (as a contract item) and at Review (as a review dimension).**

## The rule

> When a change adds or alters a value that another surface interprets, enumerate
> every consumer of that value and prove each one's classification is still correct.
>
> A value that lands in a consumer's catch-all `else` is a **finding**, not a pass.

Values this covers:

- HTTP status codes
- error / conflict codes in response bodies
- enum members
- lifecycle states
- event or webhook names
- persisted column values another process reads

Consumers to enumerate:

- the mobile client
- the web client
- a background worker or sync loop
- a webhook receiver
- another module or service
- rows already persisted under the old meaning

## Why this exists — the incident it comes from

US-095 (Capture After Evidence) added a 60-minute post-completion grace window.
Past the window, the capture endpoint returns `409 Conflict` with code
`work_item_completed`. That is a **permanent** rejection: time only moves further
from the window, so no retry can ever succeed.

The mobile sync retry classifier treated only `400 | 403 | 404` as permanent:

```ts
if (failure instanceof Error &&
  /^Evidence (request|confirmation) failed: (400|403|404)$/.test(failure.message))
  await markEvidenceCaptureFailed(...)
```

The new `409` fell through to the transient branch. Consequences:

- the capture retried on every sync pass, forever
- it never incremented `synced`, so no refresh was triggered
- it was never marked failed, so `listFailedEvidenceCaptures` never reported it
- **the operator was never told, and the photo was unrecoverable**

Silent data loss, in a story that had already passed two independent review rounds.

A second instance of the same class shipped in the same story: a confirmed
*After* photo marked a failed *Before* photo as `replaced`, because
`resolveFailedEvidenceCaptures` predicated on `workItemId + createdAt` with no
`kind`. That query was correct when only one kind existed. **The story that added
the second kind is the story that broke it.**

Both were found by a human reading code at the end of the story. Neither was
caught by: the tenant/auth/lifecycle invariants, the merge gate, the timestamp
guard, or two rounds of independent review — because none of them asks *who else
reads this value*.

## The naive fix that is wrong

Do not key on the bare status code. US-095's lifecycle precondition rejection
(operator has not started the work yet) is **also** a `409`, and it is genuinely
transient — the operator can still start the job. Classifying all `409`s as
permanent was tried and broke three tests, including a pre-existing one.

Distinguish by the response body's `code`, not the status.

## Curation checklist

For each value the change introduces or alters:

1. Name the value and its new meaning.
2. List every consumer that branches on it (grep, do not assume).
3. For each consumer: which branch does the new value take? Is that branch correct?
4. If a consumer has a catch-all, does the new value belong there, or is it
   silently mishandled?
5. For a retry/queue consumer specifically: is the condition **permanent** or
   **transient**, and does the consumer's classification match?

## Review checklist

- Does the diff add a status code, error code, enum member, or lifecycle state?
- Was every consumer enumerated in the PR body or the curation contract?
- Is there a test proving the consumer handles the new value — not just that the
  producer emits it?
- Ideally: a test asserting every documented producer code appears in the
  consumer's classifier, so the next added code fails a test rather than
  shipping silently.

## Guardrail, not just a checklist

Per DSS principle "repeated mistakes become guardrails, docs last": this
invariant is documentation because the judgment is real. But the *specific*
instance should become a test. For FieldOps:

> A test asserting that every conflict code the evidence endpoints can return is
> explicitly classified permanent-or-transient in the mobile sync classifier.

That converts this class of defect from "a reviewer must notice" to "CI fails".
