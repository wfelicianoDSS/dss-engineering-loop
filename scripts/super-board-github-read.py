#!/usr/bin/env python3
"""Bounded, read-only GitHub evidence. Exit 79 halts the selected evidence scope.

A logical read gets three total attempts. Success resets its own sequence; other
reads cannot reset it. Permanent query/auth errors stop on the first attempt.
The halt file is shared through the main checkout, including linked worktrees.
Only an explicit new run clears it with --resume after preserving the old reason.
Each halt records a class: transient_read (timeout/5xx/network/secondary limit),
permanent_read (auth/permission/query), shape (strict shape rejection) or
uncertain_write (--halt after a mutation). --auto-resume probes only a
transient_read halt, with a fixed backoff, and stops after six failures. A
missing class is permanent_read. Mutations never enter this retry helper. For
the agent-facing kinds in FORMS, a payload that fails its shape on every attempt
is the caller's malformed read, not an outage: that call exits 64 with the valid
form and the run keeps going. Scripts whose commands are fixed set
SB_GITHUB_READ_STRICT=1 to keep halting on it.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HALTED = 79
# --auto-resume exit codes for the caller: 3 = not ours to retry, 4 = gave up.
NOT_TRANSIENT = 3
AUTO_EXHAUSTED = 4
# Waits between the six probes of a transient_read halt (2, 5, 10, 20, 30 min).
AUTO_BACKOFF = (120, 300, 600, 1200, 1800, 1800)
MAX_AUTO_ATTEMPTS = 6


def now() -> int:
    """Injected clock for tests (SB_NOW); the wall clock otherwise."""
    try:
        return int(os.environ['SB_NOW'])
    except (KeyError, ValueError):
        return int(time.time())


class ReadHalted(Exception):
    pass


class GitHubErrors(ValueError):
    """GitHub's own error payload: an outage, never the caller's shape."""


# Valid read per --kind, quoted back when a payload fails its shape.
FORMS = {
    'issue': 'issue view <N> --json number,title,body',
    'comments': 'api repos/{owner}/{repo}/issues/<N>/comments --paginate --slurp',
    'json': '<gh args> (JSON output; no --jq that prints a plain string)',
    'head': 'pr view <N> --json headRefName,headRefOid --jq \'"\\(.headRefName) \\(.headRefOid)"\'',
    'body': 'pr view <N> --json body,headRefOid',
    'metadata': 'pr view <N> --json files,labels,body,additions,deletions,changedFiles',
    'state': 'issue view <N> --json state --jq .state',
}


def halt_path():
    override = os.environ.get('SB_GITHUB_HALT_FILE')
    if override:
        return Path(override)
    result = subprocess.run(['git', 'rev-parse', '--git-common-dir'], capture_output=True,
                            text=True, timeout=5, cwd=os.environ.get('SB_REPO_PATH'))
    cwd = Path(os.environ.get('SB_REPO_PATH') or Path.cwd())
    common = Path(result.stdout.strip())
    root = (cwd / common).resolve().parent if result.returncode == 0 else cwd
    return root / '.claude/super-board/github-halt.json'


def global_halt_path():
    explicit = os.environ.get('SB_GITHUB_GLOBAL_HALT_FILE')
    if explicit:
        return Path(explicit)
    scoped = os.environ.pop('SB_GITHUB_HALT_FILE', None)
    try:
        return halt_path()
    finally:
        if scoped is not None:
            os.environ['SB_GITHUB_HALT_FILE'] = scoped


def check_halt():
    if halt_path().exists() or global_halt_path().exists():
        raise ReadHalted('GitHub reads are halted; inspect the saved reason and explicitly restart the run')


def halt(reason, attempts, operation=None, cls='permanent_read'):
    path = halt_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation keeps the first failure's evidence when workers trip together.
    try:
        with path.open('x') as stream:
            json.dump({'reason': reason, 'class': cls, 'attempts': attempts,
                       'at': now(), 'operation': operation}, stream)
    except FileExistsError:
        pass
    raise ReadHalted(reason)


def read_only(args):
    if len(args) < 2:
        return False
    if args[0] in ('pr', 'issue', 'project', 'repo'):
        return args[1] in ('view', 'list', 'diff', 'checks', 'item-list', 'field-list')
    if args[0] != 'api':
        return False
    if any(a == '--input' or a.startswith('--input=') for a in args):
        return False
    if 'graphql' in args:
        # GraphQL queries use POST, but only a literal query may be retried.
        queries = [arg[6:] for arg in args if arg.startswith('query=')]
        return (len(queries) == 1 and re.match(r'\s*query\b', queries[0]) is not None
                and re.search(r'\b(?:mutation|subscription)\b', queries[0]) is None
                and not any(a.startswith('operationName=') for a in args))
    for i, arg in enumerate(args):
        if arg in ('-X', '--method') and (i + 1 == len(args) or args[i + 1] != 'GET'):
            return False
        if arg.startswith('-X') and arg not in ('-X', '-XGET'):
            return False
        if arg.startswith(('-f', '-F')):
            return False
        if arg.startswith('--method=') and arg != '--method=GET':
            return False
        if arg in ('-f', '-F', '--field', '--raw-field', '--input') or arg.startswith(('--field=', '--raw-field=', '--input=')):
            return False
    return True


def permanent_error(text):
    if re.search(r'rate limit|secondary rate', text, re.I):
        return False
    return re.search(r'Cannot query field|Unknown (?:argument|type)|Syntax Error|Parse error on|'
                     r'GRAPHQL_VALIDATION_FAILED|undefinedField|variableRequiresValidType|'
                     r'HTTP 40[134]|Bad credentials|requires authentication|Resource not accessible|'
                     r'Could not resolve to (?:a|an) |missing required scopes', text, re.I) is not None


def require(condition, why):
    if not condition:
        raise ValueError(why)


def no_errors(value):
    pages = value if isinstance(value, list) else [value]
    if any(isinstance(p, dict) and p.get('errors') for p in pages):
        raise GitHubErrors('GraphQL returned errors with incomplete data')


def validate(text, kind, meta=None, requested=None):
    if kind == 'scalar':
        require(bool(text.strip()), 'required value missing')
        return text
    if kind == 'issue-number':
        require(not text.strip() or re.fullmatch(r'[1-9][0-9]*', text.strip()), 'invalid issue lookup result')
        return text
    if kind == 'head':
        require(re.fullmatch(r'\S+ [0-9a-f]{40}\s*', text) is not None, 'missing PR branch or full head')
        return text
    if kind == 'state':
        require(text.strip() in ('OPEN', 'CLOSED'), 'missing issue state')
        return text
    if kind == 'diff':
        if not isinstance(meta, dict):
            # A worker may read a diff without supplying --meta (e.g. `gh pr diff`, or
            # `gh api ...pulls/N -H Accept: application/vnd.github.diff`). Missing metadata is a
            # caller quirk, not missing evidence, so return the diff instead of halting the card.
            return text
        files = meta.get('files') or []
        # `gh pr view --json files` caps at ~100 entries, so meta['files'] can be SHORTER than
        # the real file count while `gh pr diff` returns every file. Compare the diff's
        # `diff --git` count against changedFiles (authoritative), not the possibly-truncated
        # list — a >100-file PR (e.g. #546, 128 files) otherwise read as "diff file list
        # incomplete" and halted the card (2026-10-14).
        expected = meta.get('changedFiles', len(files))
        if expected == 0:
            require(not text.strip() and meta['additions'] == meta['deletions'] == 0, 'diff and file list disagree')
            return text
        lines = text.splitlines()
        require(sum(line.startswith('diff --git ') for line in lines) == expected, 'diff file list incomplete')
        added = removed = 0
        old_left = new_left = 0
        for line in lines:
            if line.startswith('@@ '):
                require(old_left == new_left == 0, 'diff hunk truncated')
                hunk = re.match(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', line)
                require(hunk is not None, 'diff hunk malformed')
                old_left = int(hunk[2] or 1)
                new_left = int(hunk[4] or 1)
            elif old_left or new_left:
                if line.startswith('\\ No newline'):
                    continue
                require(bool(line) and line[0] in ' +-', 'diff hunk data missing')
                if line[0] != '+': old_left -= 1
                if line[0] != '-': new_left -= 1
                if line[0] == '+': added += 1
                if line[0] == '-': removed += 1
                require(old_left >= 0 and new_left >= 0, 'diff hunk length disagrees')
            elif line and not line.startswith(('diff --git ', 'index ', '--- ', '+++ ',
                    'new file mode ', 'deleted file mode ', 'old mode ', 'new mode ',
                    'similarity index ', 'dissimilarity index ', 'rename from ', 'rename to ',
                    'copy from ', 'copy to ', 'Binary files ', '\\ No newline')):
                raise ValueError('unexpected content outside diff hunks')
        require(old_left == new_left == 0, 'diff hunk truncated')
        require(added == meta['additions'] and removed == meta['deletions'], 'diff line counts incomplete')
        return text
    value = json.loads(text)
    no_errors(value)
    if kind == 'metadata':
        require(isinstance(value, dict), 'PR metadata is not an object')
        require(isinstance(value.get('files'), list) and isinstance(value.get('labels'), list)
                and isinstance(value.get('body'), str), 'PR policy fields missing')
        require(all(type(value.get(k)) is int and value[k] >= 0 for k in ('additions', 'deletions', 'changedFiles')), 'PR counts missing')
        # gh pr view --json files caps at ~100 entries, so a large PR legitimately returns fewer
        # files than changedFiles. Truncation above the counts is fine; only a file list LONGER
        # than changedFiles is inconsistent.
        require(value['changedFiles'] >= len(value['files']), 'PR file list longer than changedFiles')
        require(all(isinstance(f, dict) and isinstance(f.get('path'), str) and f['path'] for f in value['files']), 'PR paths missing')
        require(all(isinstance(l, dict) and isinstance(l.get('name'), str) for l in value['labels']), 'PR labels missing')
    elif kind == 'items':
        require(isinstance(value, dict) and isinstance(value.get('items'), list), 'board items missing')
        require(type(value.get('totalCount')) is int and value['totalCount'] == len(value['items']), 'board item list incomplete')
        require(all(isinstance(i, dict) and isinstance(i.get('id'), str) and i['id'] and isinstance(i.get('content'), dict) for i in value['items']), 'board item data missing')
        for item in value['items']:
            content = item['content']
            require(content.get('type') in ('Issue', 'PullRequest', 'DraftIssue') and isinstance(content.get('title'), str), 'board content identity missing')
            if content['type'] != 'DraftIssue':
                require(type(content.get('number')) is int and content['number'] > 0, 'board issue number missing')
    elif kind == 'issues':
        require(isinstance(value, list) and bool(value), 'dependency pages missing')
        # Two shapes reach this kind: a GraphQL dependency read (a list of
        # `data.repository.issues` page objects) and a REST `--paginate --slurp`
        # read (a list of pages, each a list of issues). Validate whichever arrived,
        # so a REST list never raises a raw TypeError and halts the run.
        if isinstance(value[0], list):
            require(all(isinstance(page, list) for page in value), 'dependency pages malformed')
            entries = [entry for page in value for entry in page]
            require(all(isinstance(e, dict) and type(e.get('number')) is int and e['number'] > 0
                        for e in entries), 'dependency issue fields missing')
            return
        seen = set()
        for index, page in enumerate(value):
            connection = page['data']['repository']['issues']
            nodes, info = connection['nodes'], connection['pageInfo']
            require(isinstance(nodes, list) and type(info['hasNextPage']) is bool, 'dependency page malformed')
            require(info['hasNextPage'] == (index < len(value) - 1), 'dependency pagination incomplete')
            if info['hasNextPage']:
                require(isinstance(info.get('endCursor'), str) and info['endCursor'] and info['endCursor'] not in seen, 'dependency cursor repeated or missing')
                seen.add(info['endCursor'])
            require(all(isinstance(n, dict) and type(n.get('number')) is int and isinstance(n.get('body'), str)
                        and isinstance(n.get('title'), str) and n.get('state') == 'OPEN'
                        and isinstance(n.get('comments', {}).get('nodes'), list)
                        and isinstance(n.get('labels', {}).get('nodes'), list) for n in nodes), 'dependency issue fields missing')
    elif kind == 'quota':
        resources = value['resources']
        for bucket in ('graphql', 'core'):
            require(all(type(resources[bucket].get(k)) is int and resources[bucket][k] >= 0
                        for k in ('remaining', 'reset')), 'quota data missing')
    elif kind == 'projects':
        require(isinstance(value.get('projects'), list), 'project list missing')
    elif kind == 'project':
        require(isinstance(value, dict) and isinstance(value.get('id'), str) and value['id'], 'project ID missing')
    elif kind == 'fields':
        require(isinstance(value.get('fields'), list) and any(f.get('name') == 'Status' and f.get('id') and isinstance(f.get('options'), list) for f in value['fields']), 'Status field missing')
    elif kind == 'status-field':
        data = value['data']
        owner = data.get('user') or data.get('organization')
        field = owner['projectV2']['field']
        require(isinstance(field.get('id'), str) and field['id'] and isinstance(field.get('options'), list)
                and all(isinstance(o, dict) and o.get('id') and o.get('name') for o in field['options']), 'Status field missing')
    elif kind == 'permission':
        require(value.get('permission') in ('none', 'read', 'triage', 'write', 'maintain', 'admin'), 'collaborator permission missing')
    elif kind == 'comments':
        require(isinstance(value, list) and bool(value) and all(isinstance(p, list) for p in value), 'comment pages missing')
        require(all(isinstance(c, dict) and type(c.get('id')) is int and isinstance(c.get('body'), str)
                    and isinstance(c.get('user'), dict) and c.get('created_at') and c.get('updated_at')
                    for page in value for c in page), 'comment fields missing')
    elif kind == 'approval':
        require(isinstance(value, list) and bool(value), 'approval pages missing')
        heads = set()
        for i, page in enumerate(value):
            pr = page['data']['repository']['pullRequest']
            require(re.fullmatch(r'[0-9a-f]{40}', pr['headRefOid']) and pr['state'] in ('OPEN', 'CLOSED', 'MERGED'), 'PR identity missing')
            heads.add(pr['headRefOid'])
            links = pr['closingIssuesReferences']
            require(type(links['pageInfo']['hasNextPage']) is bool and links['pageInfo']['hasNextPage'] == (i < len(value) - 1), 'approval pagination incomplete')
            require(isinstance(links['nodes'], list), 'linked issues missing')
        require(len(heads) == 1, 'PR changed during approval read')
    elif kind == 'merge-state':
        require(value.get('state') in ('OPEN', 'CLOSED', 'MERGED'), 'merge outcome unreadable')
        # headRefOid is optional: the merge gate requests it (to bind the head), but the
        # post-merge verification legitimately reads only `--json state,mergeCommit`. Demanding
        # headRefOid made the helper report "merge outcome unreadable" for a valid read, and the
        # runner blocked already-merged cards (2026-10-15, #233 / PR #609). Validate it if present.
        if 'headRefOid' in value:
            require(re.fullmatch(r'[0-9a-f]{40}', value.get('headRefOid') or ''), 'merge outcome unreadable')
        if value['state'] == 'MERGED':
            require(re.fullmatch(r'[0-9a-f]{40}', (value.get('mergeCommit') or {}).get('oid', '')), 'merged commit missing')
    elif kind == 'body':
        require(isinstance(value.get('body'), str) and re.fullmatch(r'[0-9a-f]{40}', value.get('headRefOid', '')), 'PR body/head missing')
    elif kind == 'dedupe':
        require(isinstance(value, list) and len(value) < 200, 'dedupe list missing or capped; fetch complete issue history before creating')
        # Validate the fields the CALLER actually requested (a title/state projection OR body
        # evidence) — never demand `body` from a `--json number,title,state,url` read. An issue
        # with no description returns `body: null`, which is valid, not malformed.
        # (2026-10-15/16: hard-requiring `body` halted the board on such a dedupe read.)
        fields = {'number', 'body'} if requested is None else requested
        for entry in value:
            require(isinstance(entry, dict) and type(entry.get('number')) is int and entry['number'] > 0,
                    'dedupe issue fields missing')
            for field in fields - {'number'}:
                require(field in entry, f'dedupe issue {field} missing')
                if field == 'body':
                    require(entry[field] is None or isinstance(entry[field], str), 'dedupe body malformed')
                elif field in ('title', 'url', 'state'):
                    require(isinstance(entry[field], str), f'dedupe issue {field} malformed')
    elif kind in ('prs-open', 'prs-merged', 'issues-closed', 'issue'):
        entries = [value] if kind == 'issue' else value
        require(isinstance(entries, list), 'required issue/PR list missing')
        # REST --paginate --slurp returns an array of pages. Validate every
        # issue inside those pages while preserving the original output shape.
        if kind != 'issue' and entries and isinstance(entries[0], list):
            require(all(isinstance(page, list) for page in entries), 'issue/PR pages malformed')
            entries = [entry for page in entries for entry in page]
        for entry in entries:
            require(isinstance(entry, dict) and type(entry.get('number')) is int and entry['number'] > 0,
                    'issue/PR identity missing')
            fields = set(entry) if requested is None else requested
            for field in fields - {'number'}:
                require(field in entry, f'requested {field} missing')
                if field == 'body':
                    # An issue/PR with no description is `null`, not malformed.
                    require(entry[field] is None or isinstance(entry[field], str), 'body malformed')
                elif field in ('title', 'url', 'headRefName'):
                    require(isinstance(entry[field], str), f'{field} malformed')
                elif field == 'headRefOid':
                    require(isinstance(entry[field], str) and re.fullmatch(r'[0-9a-f]{40}', entry[field]), 'PR head malformed')
                elif field == 'files':
                    require(isinstance(entry[field], list) and all(isinstance(f, dict) and isinstance(f.get('path'), str) and f['path'] for f in entry[field]), 'PR files malformed')
                elif field == 'stateReason':
                    require(entry[field] in ('COMPLETED', 'NOT_PLANNED', 'REOPENED', 'DUPLICATE', None), 'closed issue reason malformed')
    elif kind == 'object':
        require(isinstance(value, dict) and bool(value), 'required object missing')
    elif kind == 'array':
        require(isinstance(value, list), 'required list missing')
    return value


def normalize_args(args):
    # `gh api` rejects --slurp together with --jq/--template ("the --slurp option is not
    # supported with --jq or --template"). Workers sometimes combine them, which made the
    # call fail and halted the run. Drop the transform so the read returns the raw slurped
    # payload the validator expects (e.g. --kind comments wants the paginated page list).
    if '--slurp' in args:
        out, i = [], 0
        while i < len(args):
            a = args[i]
            if a in ('--jq', '-q', '--template', '-t'):
                i += 2; continue
            if a.startswith('--jq=') or a.startswith('--template='):
                i += 1; continue
            out.append(a); i += 1
        args = out
    # `gh pr diff` refuses to print a diff whose content contains ANSI escape sequences unless
    # told to. Builders sometimes commit colored terminal captures as evidence logs, which then
    # fails every diff read (and the merge gate). Allow them so the read succeeds.
    if len(args) >= 2 and args[0] == 'pr' and args[1] == 'diff' and '--allow-escape-sequences' not in args:
        args = list(args) + ['--allow-escape-sequences']
    return args


def requested_fields(args):
    for index, arg in enumerate(args):
        if arg == '--json' and index + 1 < len(args):
            return set(args[index + 1].split(','))
        if arg.startswith('--json='):
            return set(arg[7:].split(','))
    return None


def needs_json(args):
    # `gh issue/pr list|view` and `gh search` print a human table unless `--json` is given. A
    # caller that omits it makes json.loads fail; under SB_GITHUB_READ_STRICT that HALTED the whole
    # board (2026-10-15). Treat the omission as a caller error for THIS call (exit 64), never a halt.
    for a, b in zip(args, args[1:]):
        if a in ('issue', 'pr') and b in ('list', 'view'):
            return True
    return 'search' in args


def read(args, kind='json', meta=None, recovering=False):
    if not read_only(args):
        raise ValueError('retry helper accepts read-only GitHub commands only')
    args = normalize_args(args)
    if not recovering:
        check_halt()
    if '--json' not in args and needs_json(args):
        raise ValueError(
            f'this read needs --json — a gh table is not JSON. Use --kind {kind} -- '
            f'{FORMS.get(kind, "<gh> … --json …")}')
    operation = {'args': args, 'kind': kind, 'meta': meta}
    last = 'GitHub read failed'
    shape_only = True  # every attempt reached GitHub and got a payload of the wrong shape
    delay = float(os.environ.get('SB_GITHUB_RETRY_DELAY', '1'))
    for attempt in range(1, 4):
        if not recovering:
            check_halt()
        try:
            result = subprocess.run(['gh', *args], capture_output=True, text=True, timeout=30)
            diagnostic = result.stderr
            if result.returncode:
                diagnostic += result.stdout
            elif kind != 'diff':
                try:
                    payload = json.loads(result.stdout)
                    diagnostic += json.dumps([p.get('errors', []) for p in (payload if isinstance(payload, list) else [payload]) if isinstance(p, dict)])
                except ValueError:
                    pass
            if permanent_error(diagnostic):
                halt('GitHub rejected a required read (query, authentication, or permission error); fix it before restarting',
                     attempt, operation, cls='permanent_read')
            if result.returncode:
                shape_only = False
                status = re.search(r'HTTP [0-9]{3}', result.stderr)
                last = 'GitHub required read failed' + (f' ({status[0]})' if status else '')
            else:
                try:
                    value = validate(result.stdout, kind, meta, requested_fields(args))
                    if not recovering:
                        check_halt()
                    return result.stdout, value
                except (ValueError, KeyError, TypeError, AttributeError, IndexError) as error:
                    last = f'GitHub required read returned incomplete evidence: {error}'
                    shape_only = shape_only and not isinstance(error, GitHubErrors)
        except (OSError, subprocess.SubprocessError):
            shape_only = False
            last = 'GitHub required read timed out or could not start'
        if attempt < 3:
            print(f'[github-read] {last}; retry {attempt + 1}/3', file=sys.stderr)
            time.sleep(max(0, delay) * attempt)
    if shape_only and kind in FORMS and not os.environ.get('SB_GITHUB_READ_STRICT'):
        raise ValueError(f'{last}; this call failed, the run continues. Valid form: --kind {kind} -- {FORMS[kind]}')
    halt(f'{last}; stopped after 3 failed attempts', 3, operation,
         cls='shape' if shape_only else 'transient_read')


def resume_saved(path, kind=None, meta_path=None, command=None):
    """Re-run the saved read (or the caller's corrected one) and archive the halt on success."""
    record = json.loads(path.read_text())
    operation = record.get('operation')
    if not isinstance(operation, dict):
        raise ReadHalted('saved failure needs manual outcome reconciliation before restart')
    if command:
        if kind != operation['kind']:
            raise ValueError('replacement recovery read must validate the same evidence kind')
        meta = json.loads(Path(meta_path).read_text()) if meta_path else operation.get('meta')
        if kind == 'diff':
            validate(json.dumps(meta), 'metadata')
        read(command, kind, meta, recovering=True)
    else:
        read(operation['args'], operation['kind'], operation.get('meta'), recovering=True)
    read(['api', 'rate_limit'], 'quota', recovering=True)
    path.replace(path.with_name(f'github-halt-{time.time_ns()}.json'))


def _attention(path, failure):
    """One line for the orchestrator; the halt itself is never deleted."""
    log = path.parent / 'needs-attention.log'
    try:
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open('a') as stream:
            stream.write('%s github-read auto-resume exhausted after %d attempts: %s (halt: %s)\n'
                         % (time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now())),
                            MAX_AUTO_ATTEMPTS, failure[:200], path))
    except OSError:
        pass


def _write_record(path, record):
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(record))
    temp.replace(path)


def auto_resume():
    """Probe a transient_read halt on a fixed backoff. Never touches any other class."""
    path = halt_path()
    if not path.exists():
        print(json.dumps({'action': 'none'}))
        return 0
    try:
        record = json.loads(path.read_text())
    except ValueError:
        record = {}
    cls = record.get('class') or 'permanent_read'
    if cls != 'transient_read' or not isinstance(record.get('operation'), dict):
        print(json.dumps({'action': 'skip', 'class': cls}))
        return NOT_TRANSIENT
    attempts = int(record.get('auto_attempts') or 0)
    if attempts >= MAX_AUTO_ATTEMPTS:
        print(json.dumps({'action': 'stop', 'attempts': attempts, 'next_probe_at': 0}))
        return AUTO_EXHAUSTED
    due = int(record.get('next_probe_at') or 0)
    if now() < due:
        print(json.dumps({'action': 'wait', 'attempts': attempts, 'next_probe_at': due}))
        return 0
    try:
        resume_saved(path)
    except (ReadHalted, ValueError, OSError, subprocess.SubprocessError) as error:
        failure = str(error)
    else:
        print(json.dumps({'action': 'resumed'}))
        return 0
    attempts += 1
    try:
        record = json.loads(path.read_text())
    except (OSError, ValueError):
        pass
    record['auto_attempts'] = attempts
    record['last_auto_error'] = failure[:300]
    if attempts >= MAX_AUTO_ATTEMPTS:
        record['next_probe_at'] = 0
        _attention(path, failure)
        _write_record(path, record)
        print(json.dumps({'action': 'stop', 'attempts': attempts, 'next_probe_at': 0}))
        return AUTO_EXHAUSTED
    record['next_probe_at'] = now() + AUTO_BACKOFF[min(attempts - 1, len(AUTO_BACKOFF) - 1)]
    _write_record(path, record)
    print(json.dumps({'action': 'wait', 'attempts': attempts,
                      'next_probe_at': record['next_probe_at']}))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kind', choices=('json','scalar','issue-number','head','state','diff','metadata','items','issues','quota','projects','project','fields','status-field','permission','comments','approval','merge-state','body','dedupe','prs-open','prs-merged','issues-closed','issue','object','array'))
    parser.add_argument('--meta')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--halt', help='record an unresolved mutation outcome and stop; never retry it')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--auto-resume', action='store_true',
                        help='probe a transient_read halt on its backoff (0 = continue/wait, 3/4 = stop)')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    try:
        if args.halt:
            os.environ['SB_GITHUB_HALT_FILE'] = str(global_halt_path())
            halt(args.halt, 1, cls='uncertain_write')
        if args.auto_resume:
            return auto_resume()
        if args.resume:
            path = halt_path()
            if path.exists():
                resume_saved(path, args.kind, args.meta, command)
            return 0
        if args.check:
            check_halt()
            return 0
        meta = json.loads(Path(args.meta).read_text()) if args.meta else None
        output, _ = read(command, args.kind or 'json', meta)
        sys.stdout.write(output)
        return 0
    except ReadHalted as error:
        print(f'[github-read] HALT: {error}. Saved at {halt_path()}', file=sys.stderr)
        return HALTED
    except (ValueError, OSError) as error:
        print(f'[github-read] {error}', file=sys.stderr)
        return 64


if __name__ == '__main__':
    sys.exit(main())
