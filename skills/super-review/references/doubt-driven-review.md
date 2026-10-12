# Doubt-driven review (Reviewer)

The Reviewer's job is to break the diff, not confirm it. For each non-trivial claim, run
the loop below before trusting it. This is the Reviewer's own skeptical pass; it
complements the adversarial sub-agents (code-grounder / historian), it does not replace
them.

**CLAIM → EXTRACT → DOUBT → RECONCILE → STOP**

1. **CLAIM** — restate what the PR asserts, in one sentence
   ("this rejects a missing reason with a check constraint").
2. **EXTRACT** — pull the concrete evidence: the file:line, the test, the exact command
   and its output.
3. **DOUBT** — attack it with at least one falsifying question per claim:
   - "What input makes this fail?"
   - "Does NULL / empty / the boundary value slip through?"
   - "Is this the real artifact or a proxy? Would the test still pass if the code were
     deleted?"
   - "Did they read the current docs, or their memory?"
4. **RECONCILE** — run the smallest verification that settles the doubt and read the
   actual value. A check constraint is settled by an insert, not by reading the
   migration SQL.
5. **STOP** — record the outcome (✅ held with file:line, or ❌ finding with class +
   severity), then move to the next claim.

Do not skip a claim because the Builder's summary sounds confident. Confidence is the
Builder's, not evidence.

## Cross-model check (high-risk only)

For high-risk or irreversible changes, ask a different provider (Codex / OpenRouter /
DeepSeek via the fallback lanes) the same falsifying questions and take the majority
verdict. Never switch providers inside one review decision without recording the handoff;
a fresh agent restarts the role from the durable board state.

## Aggregation

A doubt that survives every attempt to kill it is a held claim. A doubt you cannot
settle is a **Verification miss** (the code may be right, the evidence does not prove
it) — it lowers the confidence score, per the adversarial mode's aggregation rule.
