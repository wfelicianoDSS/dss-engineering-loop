#!/usr/bin/env bash
# super-board installer.
# Copies skills/, scripts/, workflows/ and the guard hooks into the target
# project's .claude/ tree, and merges the hook settings into
# .claude/settings.json (backed up first, never duplicated).
#
# Usage:
#   ./install.sh [--no-hooks] [--protect-main] [--overwrite-local] [target-project-dir]
# Defaults to the current working directory. --no-hooks skips the guard hooks
# and leaves settings.json untouched. --protect-main also wires the opt-in
# guard that blocks direct and force pushes to main/master/base_branch; with
# --no-hooks it installs that one guard alone. The installer asks nothing:
# super-board onboard asks the questions (protect main is one of them).
#
# Control-plane files (scripts, workflows, hooks) are recorded with their
# sha256 in .claude/super-board/install-manifest.json. On a reinstall, a file
# that no longer matches the manifest is a LOCAL change: it is kept and
# reported ("kept local change: …") instead of being silently overwritten.
# --overwrite-local takes the pack version and keeps the old file as
# <path>.local-<timestamp>. The first install after this change adopts the
# current files as the baseline; there is no manifest to compare against yet.
#
# Output is grouped with emojis, one line per group of files (failures still name
# the file). Environment: SUPER_BOARD_QUIET_NEXT=1 prints only the "🔧 installing"
# group — get.sh sets it and prints its own header and summary around it.
#
# An older super-board already in the target (a different skills/super-board/VERSION,
# or one with no VERSION) is recorded in .claude/super-board/upgrade.json
# {from, to, added_skills}; onboard's 🔍 Checks finishes the upgrade and lists it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS=1
PROTECT=0
OVERWRITE_LOCAL=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --no-hooks) HOOKS=0 ;;
    --protect-main) PROTECT=1 ;;
    --overwrite-local) OVERWRITE_LOCAL=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 64 ;;
    *) TARGET="$arg" ;;
  esac
done
TARGET="${TARGET:-$PWD}"

# Primary: the board and its lanes. Secondary: standalone helpers the lanes
# can call (visual, git-sync, ui-refine-loop). Worktree cleanup (cleanup-wt) is a
# hook, not a skill: it ships with the guard hooks below.
PRIMARY_SKILLS="super-board super-build super-qa super-review super-collect"
SECONDARY_SKILLS="visual git-sync ui-refine-loop"

if [ ! -d "$TARGET" ]; then
  echo "target directory not found: $TARGET" >&2
  exit 64
fi

QUIET="${SUPER_BOARD_QUIET_NEXT:-}"
PACK_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || echo '?')"

# Record an upgrade BEFORE the copy overwrites the old VERSION.
PREV_VERSION=""
if [ -d "$TARGET/.claude/skills/super-board" ]; then
  PREV_VERSION="$(tr -d '[:space:]' < "$TARGET/.claude/skills/super-board/VERSION" 2>/dev/null || echo 'older')"
  [ -n "$PREV_VERSION" ] || PREV_VERSION="older"
fi
ADDED_SKILLS=""
if [ -n "$PREV_VERSION" ]; then
  for skill in $PRIMARY_SKILLS $SECONDARY_SKILLS; do
    [ -e "$TARGET/.claude/skills/$skill" ] || ADDED_SKILLS="$ADDED_SKILLS $skill"
  done
fi

[ -n "$QUIET" ] || echo "🧩 super-board $PACK_VERSION → $TARGET"
echo "🔧 installing"

# Resolve all skill paths before replacing anything. A destination can contain
# the pack (or a linked source skill); clearing it would destroy our input.
# A destination inside its source would instead recursively copy into itself.
python3 - "$REPO_ROOT" "$TARGET" $PRIMARY_SKILLS $SECONDARY_SKILLS <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
target = Path(sys.argv[2])
for skill in sys.argv[3:]:
    src = (root / "skills" / skill).resolve()
    dest = (target / ".claude" / "skills" / skill).resolve()
    if src == dest:
        continue
    if dest == root or dest in root.parents or dest in src.parents or src in dest.parents:
        sys.exit(f"    ✗ refusing to install {skill}: source and destination overlap ({dest})")
PY

mkdir -p "$TARGET/.claude/skills" "$TARGET/.claude/bin"

# ── install manifest: keep local edits to control-plane files ────────────────
# scripts/, workflows/ and hooks/ are copied over an existing install. Without a
# record, a reinstall silently overwrites a local hotfix — the "scripts/ vs
# .claude/bin drift" that hides a control-plane fix. The manifest stores the
# sha256 of what the pack last installed; a target file that differs from it is
# a local change and is kept unless --overwrite-local is passed.
MANIFEST_DIR="$TARGET/.claude/super-board"
MANIFEST="$MANIFEST_DIR/install-manifest.json"
# The backup suffix is only needed when a conflict is actually replaced, and it
# must not add a date(1) dependency to a plain install (tests/test-get.sh runs
# the installer with a minimal PATH).
STAMP=""
local_stamp() {
  [ -n "$STAMP" ] && return 0
  STAMP="$(date +%Y%m%d%H%M%S 2>/dev/null \
    || python3 -c 'import time; print(time.strftime("%Y%m%d%H%M%S"))')"
}
OLD_MANIFEST="$(mktemp)"; NEW_MANIFEST="$(mktemp)"
trap 'rm -f "$OLD_MANIFEST" "$NEW_MANIFEST"' EXIT
if [ -f "$MANIFEST" ]; then
  python3 - "$MANIFEST" > "$OLD_MANIFEST" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for path, sha in (data.get("files") or {}).items():
    print("%s\t%s" % (path, sha))
PY
fi
KEPT_LOCAL=0
# Prefer the native hasher (fast); fall back to python3, which is already
# required, so a minimal PATH (tests/test-get.sh) still works. No awk/cut.
hash_file() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then out=$(sha256sum "$1")
  elif command -v shasum >/dev/null 2>&1; then out=$(shasum -a 256 "$1")
  else out=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1")
  fi
  printf '%s' "${out%% *}"
}
manifest_hash() {
  local line
  line=$(grep -m1 -F -- "$1"$'\t' "$OLD_MANIFEST" 2>/dev/null) || true
  [ -n "$line" ] || return 0
  printf '%s' "${line#*$'\t'}"
}
record_file() { printf '%s\t%s\n' "$1" "$2" >> "$NEW_MANIFEST"; }
# install_file <absolute-src> <path-under-target> [exec]
# Keeps a locally modified file (recorded in the manifest with a different hash),
# unless --overwrite-local is given. A skipped file keeps its old manifest hash,
# so the next reinstall still sees it as modified instead of adopting the edit.
install_file() {
  local src="$1" rel="$2" mode="${3:-}" dest prev cur
  dest="$TARGET/$rel"
  prev="$(manifest_hash "$rel")"
  if [ -f "$dest" ] && [ -n "$prev" ]; then
    cur="$(hash_file "$dest")"
    if [ "$cur" != "$prev" ]; then
      if [ "$OVERWRITE_LOCAL" -eq 1 ]; then
        local_stamp
        cp -p "$dest" "$dest.local-$STAMP" 2>/dev/null || cp "$dest" "$dest.local-$STAMP"
        echo "   ↺ local change replaced: $rel (backup: $rel.local-$STAMP)"
      else
        echo "   ⚠️  kept local change: $rel — upstream it or pass --overwrite-local"
        record_file "$rel" "$prev"
        KEPT_LOCAL=$((KEPT_LOCAL + 1))
        return 0
      fi
    fi
  fi
  mkdir -p "$(dirname "$dest")"
  copy_file "$src" "$dest"
  if [ "$mode" = exec ]; then chmod +x "$dest"; fi
  record_file "$rel" "$(hash_file "$src")"
}

# A project may keep the real skill directories elsewhere and symlink them into
# .claude/skills — a layout some repos use to share one tree between .claude and
# another agent host. `cp -R src dest/` fails outright on such a target ("Not a
# directory"), so resolve the link and write to where it actually points. That
# keeps the project's chosen layout instead of replacing it with a plain copy.
for skill in $PRIMARY_SKILLS $SECONDARY_SKILLS; do
  if [ ! -d "$REPO_ROOT/skills/$skill" ]; then
    echo "    ✗ missing $skill in repo — skipping" >&2
    continue
  fi
  dest="$TARGET/.claude/skills/$skill"
  note=""
  if [ -L "$dest" ]; then
    # `cd -P` walks the link to its physical target in one step. Do NOT rebuild
    # the path from `readlink` output: `cd ""` SUCCEEDS in bash, so an empty
    # readlink silently leaves you in the parent, and the rm below then empties
    # .claude/skills instead of one skill. That is not hypothetical — it deleted
    # 190 entries on a real repo on 2026-08-20 before this comment existed.
    resolved=$(cd -P "$dest" 2>/dev/null && pwd) || resolved=""
    if [ -z "$resolved" ]; then
      echo "    ✗ $skill is a symlink pointing nowhere — skipping rather than replacing it" >&2
      continue
    fi
    dest="$resolved"
    note=" (via symlink → ${resolved#$TARGET/})"
  fi

  # Belt and braces: whatever the resolution produced, it must be a path ENDING
  # in this skill's own name. Anything else is a bug in the line above, and the
  # blast radius of being wrong here is the user's entire skills tree.
  case "$dest" in
    */"$skill") : ;;
    *) echo "    ✗ refusing to write $skill: resolved to '$dest', which is not a $skill directory" >&2
       continue ;;
  esac

  # A self-vendored project can expose this very source through one or more
  # links. There is nothing to copy in that case; clearing dest erases src too.
  if [ "$REPO_ROOT/skills/$skill" -ef "$dest" ]; then
    echo "   ✓ $skill already uses the source directory"
    continue
  fi

  # Replace the contents, not the directory itself, so a symlink stays a symlink.
  mkdir -p "$dest"
  rm -rf "${dest:?}/"* 2>/dev/null || true
  cp -R "$REPO_ROOT/skills/$skill/." "$dest/"
  [ -z "$note" ] || echo "   ✓ $skill$note"
done

# File destinations can be links into the pack too. -ef follows symlinks and
# also recognizes hard links, so cp never tries to overwrite its own input.
copy_file() {
  if [ ! "$1" -ef "$2" ]; then
    cp "$1" "$2"
  fi
}

for script in super-board-project-verifier.py super-board-skills-ready.py super-board-calibration.py super-board-verification-ready.py super-board-github-read.py super-board-collect-state.py super-board-run.sh super-board-gh-guard.sh super-board-card.sh super-board-status.py super-board-wave-plan.sh super-board-codex-lane.sh super-board-codex-wave.sh super-board-deps.sh super-board-preflight.sh super-board-merge-gate.sh super-board-merge-policy.py super-board-approval.py super-board-env-check.sh super-board-agents-md.py super-board-settings.py super-board-setup.py super-board-usage.sh super-board-throttle.sh super-board-host.sh super-board-pr-body.sh super-review-file-refactor.sh super-qa-file-bug.sh super-board-stop.sh super-board-openrouter-lane.sh super-board-openrouter-balance.sh super-board-deepseek-lane.sh super-board-deepseek-balance.sh super-board-watchdog.sh super-board-guard.sh super-board-autostart.sh super-board-evidence-check.sh super-board-promote.sh super-board-report.py super-board-test-mix.sh; do
  if [ -f "$REPO_ROOT/scripts/$script" ]; then
    install_file "$REPO_ROOT/scripts/$script" ".claude/bin/$script" exec
  fi
done

mkdir -p "$TARGET/.claude/workflows"
for wf in super-board-wave.js ui-refine-loop.js; do
  if [ -f "$REPO_ROOT/workflows/$wf" ]; then
    install_file "$REPO_ROOT/workflows/$wf" ".claude/workflows/$wf"
  fi
done
echo "   ✓ skills, scripts and workflows → .claude/"

SETTINGS_PY="$REPO_ROOT/scripts/super-board-settings.py"
# Stdlib-only merge (scripts/super-board-settings.py): keeps every existing key
# and hook, adds each guard command once per event + matcher, backs the file up
# before writing, and leaves an invalid settings.json untouched (exit 2).
# Prints one summary word for the settings line; the helper's own lines (an
# invalid-JSON refusal) go to stderr untouched.
merge_settings() {
  local had=0 res rc=0
  [ -f "$TARGET/.claude/settings.json" ] && had=1
  res=$(python3 "$SETTINGS_PY" hooks "$TARGET/.claude/settings.json" "$@" 2>&1) || rc=$?
  if [ "$rc" -eq 2 ]; then printf '%s\n' "$res" >&2; echo "not valid JSON — left untouched"
  elif echo "$res" | grep -q "already present"; then echo "already present"
  elif [ "$had" -eq 1 ]; then echo "backup kept"
  else echo "new file"; fi
}

if [ "$HOOKS" -eq 1 ]; then
  mkdir -p "$TARGET/.claude/hooks"
  # hooks/*.py only: hooks/dev/ holds gates for repos that author skills, never installed.
  n=0
  for h in "$REPO_ROOT"/hooks/*.py; do
    [ -f "$h" ] || continue
    install_file "$h" ".claude/hooks/$(basename "$h")" exec
    n=$((n + 1))
  done
  SNIPPETS="$REPO_ROOT/hooks/settings-snippet.json"
  if [ "$PROTECT" -eq 1 ]; then SNIPPETS="$SNIPPETS $REPO_ROOT/hooks/settings-protect-main.json"; fi
  # shellcheck disable=SC2086
  echo "   🛡️  $n guard hooks → .claude/settings.json ($(merge_settings $SNIPPETS))"
elif [ "$PROTECT" -eq 1 ]; then
  # --no-hooks --protect-main: the one guard asked for, nothing else. This is the
  # command onboard names when its protect-main question finds no guard script.
  mkdir -p "$TARGET/.claude/hooks"
  install_file "$REPO_ROOT/hooks/guard-protected-push.py" ".claude/hooks/guard-protected-push.py" exec
  echo "   🛡️  --no-hooks: only the push guard → .claude/settings.json ($(merge_settings "$REPO_ROOT/hooks/settings-protect-main.json"))"
else
  echo "   ⏭️  guard hooks skipped (--no-hooks)"
fi

# AGENTS.md: a re-install refreshes the managed super-board block and touches
# nothing outside its markers. No block yet → onboard writes it (with consent).
if [ -f "$TARGET/AGENTS.md" ] && grep -q '^<!-- super-board:begin' "$TARGET/AGENTS.md"; then
  python3 "$REPO_ROOT/scripts/super-board-agents-md.py" block --root "$TARGET" \
    --template "$REPO_ROOT/skills/super-board/references/agents-md-block.md" \
    --version "$PACK_VERSION" >/dev/null 2>&1 \
    && echo "   📜 AGENTS.md: super-board block refreshed" \
    || echo "   ! AGENTS.md: couldn't refresh the super-board block — onboard repairs it"
fi
if [ -f "$TARGET/CLAUDE.md" ] && ! grep -m1 -v '^[[:space:]]*$' "$TARGET/CLAUDE.md" | grep -qx '@AGENTS.md'; then
  echo "   ! CLAUDE.md holds its own rules — onboard offers a merge"
fi

# Upgrade record for onboard's 🔍 Checks (it migrates config, labels, columns).
if [ -n "$PREV_VERSION" ] && [ "$PREV_VERSION" != "$PACK_VERSION" ]; then
  mkdir -p "$TARGET/.claude/super-board"
  python3 - "$TARGET/.claude/super-board/upgrade.json" "$PREV_VERSION" "$PACK_VERSION" $ADDED_SKILLS <<'PY'
import json, sys, time
path, frm, to, added = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
try:
    old = json.load(open(path))
except Exception:
    old = {}
rec = {"from": old.get("from", frm), "to": to, "added_skills": sorted(set(old.get("added_skills", []) + added)),
       "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
json.dump(rec, open(path, "w"), indent=2)
PY
  echo "   ⬆️  upgrade from $PREV_VERSION — onboard finishes it (config, labels, columns)"
fi

# Record what this run installed (and kept). Written last so a kept file keeps
# its previous pack hash and is still seen as modified on the next reinstall.
mkdir -p "$MANIFEST_DIR"
python3 - "$MANIFEST" "$PACK_VERSION" "$NEW_MANIFEST" <<'PY'
import json, sys, time
path, version, tsv = sys.argv[1], sys.argv[2], sys.argv[3]
files = {}
with open(tsv) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if "\t" in line:
            rel, sha = line.split("\t", 1)
            files[rel] = sha
record = {"version": version, "installed_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
          "files": dict(sorted(files.items()))}
with open(path, "w") as fh:
    json.dump(record, fh, indent=2)
    fh.write("\n")
PY
if [ "$KEPT_LOCAL" -gt 0 ]; then
  echo "   ⚠️  $KEPT_LOCAL local change(s) kept — re-run with --overwrite-local to take the pack version"
fi

if [ -z "$QUIET" ]; then
  echo "🎉 super-board $PACK_VERSION is installed"
  echo "👉 next: open Claude Code here and run /super-board onboard"
fi
