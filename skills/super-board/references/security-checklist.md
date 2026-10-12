# Security checklist (Reviewer, pre-merge)

Clear every item before calling a PR merge-ready. Grounded in OWASP, applied to this
repo's tenant model. The guard hooks (`guard-secrets`, `guard-key-literals`,
`guard-protected-push`) enforce some of these mechanically; the Reviewer verifies the rest.

- [ ] **Tenant isolation** — every query scoped to `ICurrentOrganization.OrganizationId`;
      no cross-tenant read or write; missing/foreign rows are indistinguishable 404s.
- [ ] **Authorization** — endpoints require `RequireAuthorization("permission:…")`;
      any `AllowAnonymous` route is a signed, short-lived token (e.g. the evidence
      content proxy) and nothing else.
- [ ] **Secrets** — no keys, tokens, or credentials in code, diffs, logs, or comments.
- [ ] **Input** — length/format validation at the boundary; no raw user input becomes a
      path, SQL fragment, or URL component.
- [ ] **Injection** — parameterized queries / EF only; no string-built SQL.
- [ ] **Storage** — object-store URLs are scoped and short-lived; the raw storage key
      never leaves the server (US-099 AC).
- [ ] **Errors** — no stack traces or sensitive data in responses or logs.

Any item that cannot be verified is a **Verification miss**, not a pass.
