#!/usr/bin/env python3
"""super-board-merge-policy.py — decide who merges a PR and which migrations run.

Called by super-board-merge-gate.sh inside the merge lock. Pure function of the
config, the PR metadata and the diff; no network, no side effects.

    super-board-merge-policy.py --config <cfg.json> --meta <pr.json> --diff <file>

`--meta` is `gh pr view --json labels,files,additions,deletions,body`.
`--diff` is `gh pr diff` (only ADDED lines are searched for keywords).

Governance-enabled configs additionally return risk and risk_reasons. They classify
added and removed lines (excluding generated EF Down inverse operations), reserve
human for CRITICAL categories, and route oversized PRs to HIGH specialist scrutiny.
Legacy rules below apply only when governance is disabled.

Stdout, one JSON object:
    { "human":      [ {"category": "money", "why": "path src/billing/charge.ts"} ],
      "migrations": [ "supabase/migrations/2026_add_col.sql" ],
      "run":        [ {"env": "staging", "cmd": "npm run db:migrate:staging"} ],
      "needs_you":  [ "npm run db:migrate:live   # live: not in allowed_envs" ],
      "done":       false }

`human` non-empty → the gate exits 7 (a human merges). `needs_you` non-empty →
exit 8 unless the gate verifies a head-bound approval. `done` stays false for
compatibility: labels never supply authority. Exit 2 on
unreadable metadata, so the gate fails safe to "human".

Rules, from references/config-schema.json → merge_policy / migrations:
- merge_policy.default "human" → everything waits for a human.
- merge_policy.auto_max_lines (default 400; 0 = no cap): changed lines
  (additions + deletions) above it → human ("big PR — please review"). Files
  matching merge_policy.size_exclude (default: lockfiles, generated output,
  snapshots) and migration files (migrations.globs) do not count; migration
  lines are reported separately. Per-file counts come from `files[].additions/
  deletions`; without them the PR totals are used.
- merge_policy.always_human.<category>: any label, path glob or added-line
  keyword match → human. Categories ship as money, auth, schema; setting
  always_human replaces them all (`{}` turns category gating off).
- migrations: a changed path matching migrations.globs makes this a migration
  PR. Every env in allowed_envs with a command runs (a command of "-" means the
  deploy pipeline applies it: nothing to run). target_env not in allowed_envs, or
  allowed with no command → needs you. migrations.human_steps (any migration PR)
  and `needs-you: <command>` lines in the PR body (any PR) → needs you.
Globs: `**/` any directories (incl. none), `**` anything, `*` within one path
segment, `?` one character.
"""
from __future__ import annotations

import argparse
import json
import re
import sys

DEFAULT_ALWAYS_HUMAN = {
    "money": {
        "labels": ["money", "payments", "billing", "pricing"],
        "paths": ["**/billing/**", "**/payments/**", "**/stripe/**", "**/checkout/**"],
        "keywords": ["stripe.", "payment_intent", "price_id", "invoice.create"],
    },
    "auth": {
        "labels": ["auth", "security"],
        "paths": ["**/auth/**", "**/authz/**", "**/permissions/**"],
        "keywords": ["jwt.sign", "bcrypt", "password_hash", "service_role"],
    },
    "schema": {
        "labels": ["schema", "destructive"],
        "paths": [],
        "keywords": ["drop table", "drop column", "truncate table", "rename column", "drop schema",
                     "delete from"],
    },
}
DEFAULT_MIGRATION_GLOBS = [
    "supabase/migrations/**", "prisma/migrations/**", "drizzle/**",
    "**/migrations/*.sql", "db/migrate/**", "alembic/versions/**",
]
DEFAULT_ALLOWED_ENVS = ["test", "staging"]
DEFAULT_AUTO_MAX_LINES = 400
DEFAULT_SIZE_EXCLUDE = [
    # lockfiles
    "**/package-lock.json", "**/yarn.lock", "**/pnpm-lock.yaml", "**/bun.lockb", "**/bun.lock",
    "**/npm-shrinkwrap.json", "**/Cargo.lock", "**/poetry.lock", "**/uv.lock", "**/Pipfile.lock",
    "**/Gemfile.lock", "**/composer.lock", "**/go.sum", "**/Podfile.lock", "**/pubspec.lock",
    # generated output
    "**/generated/**", "**/__generated__/**", "**/*.generated.*", "**/*.gen.*",
    "**/*.min.js", "**/*.min.css", "**/*.map", "**/*.pb.go", "**/*_pb2.py",
    # snapshots
    "**/__snapshots__/**", "**/*.snap",
]


def glob_re(pattern: str) -> re.Pattern:
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif pattern.startswith("**", i):
            out += ".*"; i += 2
        elif pattern[i] == "*":
            out += "[^/]*"; i += 1
        elif pattern[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(pattern[i]); i += 1
    return re.compile("^" + out + "$")


def matches(path: str, globs) -> str | None:
    for g in globs or []:
        if glob_re(g).match(path):
            return g
    return None


# Keyword gates (destructive-data, auth, money) must scan CODE, not the test-evidence and
# doc artifacts the board commits. A QA log that merely quotes SQL (`DELETE FROM ...`) or an
# identifier tripped the destructive-data human gate on a clean PR (2026-10-15), so added/removed
# lines under these paths are skipped. Override with merge_policy.keyword_exclude.
DEFAULT_KEYWORD_EXCLUDE = [
    "docs/**", "**/*.md", "**/*.log", "**/*.txt",
    "**/__snapshots__/**", "**/*.snap",
    # Test code legitimately contains SQL strings (e.g. proving a FK RESTRICT blocks a
    # cascade); a `DELETE FROM` literal there is not a destructive production operation.
    "**/tests/**", "**/test/**",
    "**/package-lock.json", "**/bun.lock", "**/yarn.lock", "**/pnpm-lock.yaml",
]


def added_text(diff: str, excl) -> str:
    parts, path = [], None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            p = line[4:].strip()
            path = p[2:] if p.startswith("b/") else p
        elif line.startswith("+") and not line.startswith("+++"):
            if path is None or not matches(path, excl):
                parts.append(line[1:])
    return "\n".join(parts).lower()


def rule_hits(rules, labels, paths, changed):
    hits = []
    for category, rule in rules.items():
        hit = next((f"label {label}" for label in rule.get("labels", [])
                    if label.lower() in labels), None)
        hit = hit or next((f"path {path}" for path in paths
                           if matches(path, rule.get("paths"))), None)
        hit = hit or next((f"keyword {keyword}" for keyword in rule.get("keywords", [])
                           if keyword.lower() in changed), None)
        if hit:
            hits.append({"category": category, "why": hit})
    return hits


def governance_changes(diff, excl=()):
    # Generated EF rollback methods contain inverse destructive operations.
    # Only their forward Up operations classify destructive migration risk.
    # Evidence/doc/log paths are skipped: they only quote identifiers/SQL.
    changed, rollback, migration, path = [], False, False, None
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            rollback = False
            migration = "/migrations/" in line.lower()
            path = None
        elif line.startswith("+++ "):
            p = line[4:].strip()
            path = p[2:] if p.startswith("b/") else p
        if migration and "protected override void Down(" in line:
            rollback = True
        if migration and "protected override void Up(" in line:
            rollback = False
        inverse = rollback and re.search(
            r"migrationBuilder\.(DropColumn|DropTable|DropIndex|DropForeignKey|RenameColumn|RenameTable|RenameIndex|AlterColumn)\s*\(", line)
        if not inverse and line[:1] in ("+", "-") and not line.startswith(("+++", "---")):
            if path is None or not matches(path, excl):
                changed.append(line[1:])
    return "\n".join(changed).lower()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--diff", required=True)
    a = ap.parse_args()

    cfg = json.load(open(a.config))
    try:
        meta = json.load(open(a.meta))
    except ValueError:
        return 2
    if not isinstance(meta, dict) or "files" not in meta:
        return 2
    diff = open(a.diff, errors="replace").read()

    labels = {(l.get("name") or "").lower() for l in meta.get("labels") or []}
    paths = [f.get("path") or "" for f in meta.get("files") or []]
    kw_excl = (cfg.get("merge_policy") or {}).get("keyword_exclude")
    kw_excl = DEFAULT_KEYWORD_EXCLUDE if kw_excl is None else kw_excl
    added = added_text(diff, kw_excl)
    body = meta.get("body") or ""

    policy = cfg.get("merge_policy") or {}
    human = []
    if (policy.get("default") or "auto") == "human":
        human.append({"category": "default", "why": "merge_policy.default is \"human\""})
    mig = cfg.get("migrations") or {}
    globs = mig.get("globs") or DEFAULT_MIGRATION_GLOBS
    mig_files = [p for p in paths if matches(p, globs)]

    cap = policy.get("auto_max_lines")
    cap = DEFAULT_AUTO_MAX_LINES if cap is None else int(cap)
    excl = policy.get("size_exclude")
    excl = DEFAULT_SIZE_EXCLUDE if excl is None else excl
    files = meta.get("files") or []
    if files and all("additions" in f for f in files):
        size = mig_lines = 0
        for f in files:
            n = int(f.get("additions") or 0) + int(f.get("deletions") or 0)
            p = f.get("path") or ""
            if p in mig_files:
                mig_lines += n
            elif not matches(p, excl):
                size += n
    else:
        size, mig_lines = int(meta.get("additions") or 0) + int(meta.get("deletions") or 0), 0
    if cap > 0 and size > cap:
        extra = f" (+{mig_lines} migration lines counted separately)" if mig_lines else ""
        human.append({"category": "size",
                      "why": f"big PR — please review: {size} changed lines > auto_max_lines {cap}{extra}"})
    always = policy["always_human"] if isinstance(policy.get("always_human"), dict) else DEFAULT_ALWAYS_HUMAN
    for cat, rule in always.items():
        rule = rule or {}
        hit = next((f"label {l}" for l in rule.get("labels") or [] if l.lower() in labels), None)
        if not hit:
            hit = next((f"path {p} (matches {g})" for p in paths
                        for g in [matches(p, rule.get("paths"))] if g), None)
        if not hit:
            hit = next((f"keyword \"{k}\" in an added line" for k in rule.get("keywords") or []
                        if k.lower() in added), None)
        if hit:
            human.append({"category": cat, "why": hit})

    governance = cfg.get("governance") or {}
    risk, reasons = None, []
    if governance.get("enabled"):
        changed = governance_changes(diff, kw_excl)
        critical = rule_hits(always, labels, paths, changed)
        high = rule_hits(governance.get("high", {}), labels, paths, changed)
        medium = rule_hits(governance.get("medium", {}), labels, paths, changed)
        # Size increases specialist scrutiny; it is not a human risk category.
        if cap > 0 and size > cap:
            high.append({"category": "size", "why": f"{size} changed lines > {cap}"})
        human = critical
        reasons = critical or high or medium
        risk = "CRITICAL" if critical else "HIGH" if high else "MEDIUM" if medium else "LOW"

    run, needs = [], []
    if mig_files:
        allowed = mig.get("allowed_envs")
        allowed = DEFAULT_ALLOWED_ENVS if allowed is None else allowed
        base = cfg.get("base_branch") or "main"
        target = mig.get("target_env") or ("live" if base in ("main", "master") else "staging")
        cmds = mig.get("commands") or {}
        for env in allowed:
            cmd = (cmds.get(env) or "").strip()
            if cmd and cmd != "-":
                run.append({"env": env, "cmd": cmd})
            elif env == target and not cmd:
                needs.append(f"<your {env} migrate command>   # {env}: allowed, but migrations.commands.{env} is not set")
        if target not in allowed:
            cmd = (cmds.get(target) or "").strip()
            if cmd != "-":
                needs.append(f"{cmd or '<your ' + target + ' migrate command>'}   # {target}: the base deploys here and it is not in allowed_envs")
        needs += [str(s) for s in mig.get("human_steps") or []]
    for line in body.splitlines():
        m = re.match(r"^\s*(?:[-*]\s*)?needs-you:\s*(.+?)\s*$", line, re.I)
        if m and m.group(1).lower() != "done":
            needs.append(m.group(1).strip("`"))

    print(json.dumps({"human": human, "migrations": mig_files, "run": run,
                      "needs_you": needs, "done": False,
                      "risk": risk, "risk_reasons": reasons}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
