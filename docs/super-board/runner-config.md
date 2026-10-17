# Runner configuration (FieldOps headless runner)

Keys read by the ported runner (`scripts/super-board-run.sh` and friends), with defaults. The
schema file (`skills/super-board/references/config-schema.json`) still documents the workflow
pack; this is the runner contract, and it is what `config-schema.json` should grow to match.

| Key | Default | Meaning |
|---|---|---|
| `base_branch` | `main` | Branch cards merge into and the checkout must be on |
| `tick_seconds` | `120` | Tick cadence |
| `max_workers` | `3` | Cap on concurrent lane workers |
| `build_slots` | `1` | Parallel build lanes (1–2) |
| `no_progress_cycles` | `6` | Ticks without a Done before the runaway guard trips |
| `max_dispatches` | `0` | Dispatch ceiling; `0` = none |
| `progress_seconds` | `120` | Heartbeat interval for a running worker |
| `lease_ttl_seconds` | `2700` | A lease heartbeat older than this is escalated; at 2× the worker is terminated |
| `rebuild_cap` | `2` | Rebuild/review bounces before a card is parked |
| `verify_commands` | `[]` | Commands the merge gate runs to prove the merge builds |
| `usage_order` | `[claude, codex]` | Build/QA provider order |
| `usage_fallback` | `[]` | Extra provider legs after `usage_order` |
| `review.providers` | `[claude, codex]` | Review provider order (fallback only leaves Claude) |
| `lane_backend` | `claude` | Backend for the build/QA lanes |
| `groom.enabled` | `true` | Intake lane on/off |
| `groom.backend` | `claude` | Legacy groom backend |
| `groom.providers` | `[deepseek, openrouter]` | Groom provider order |
| `groom.ready_floor` | `1` | Groom only while `Ready <= ready_floor` |
| `groom.cooldown_seconds` | `1800` | Force a groom even when the backlog is unchanged |
| `groom.max_cards_per_run` | `5` | Cards a groom run may move |
| `notifications.channel` | `session` | Where notifications go |
| `notifications.bot_identity` | — | Login used for claims/assignee sweeps |
| `human_approves_merge` | `false` | Require a human merge for every card |
| `merge_policy.default` | `auto` | `auto` merges on evidence; `human` requires a person |
| `merge_policy.auto_max_lines` | `400` | Size gate (migration lines excluded) |
| `merge_policy.keyword_exclude` | defaults | Paths the destructive-data keyword scan skips (`tests/**`, docs, logs…) |
| `migrations.globs` | defaults | Paths that make a PR a migration PR |
| `migrations.allowed_envs` | `[test, staging]` | Envs the robot may migrate |
| `migrations.target_env` | `live` (main) | The deploy env; not in `allowed_envs` → human step |
| `migrations.commands.<env>` | — | Migrate command per env; `"-"` = the pipeline applies it |
| `governance.enabled` | `false` | HIGH/CRITICAL risk classification |
| `timezone` | `America/Puerto_Rico` | Local clock for the manifest and status |

**Provider pauses** live in `.claude/super-board/provider-pauses/<name>` (presence = parked; TTL
`SB_PAUSE_TTL`, default 30 min). A lane with no provider writes a throttled entry to
`.claude/super-board/needs-attention.log`.

**Provider health** is `.claude/super-board/providers/<name>.json` (`state`, `paused_until`,
`consecutive_failures`, `probe_interval`). A quota limit pauses until the reset (or 5 min), then
allows exactly one probe; 3 non-quota failures open the circuit for 30 min. Managed by
`super-board-providers.py`; a missing file means `ok`.

**Leases** (`inflight/<issue>`) carry `HEARTBEAT=` (rewritten by the worker's `--check`). A live
pid beyond `lease_ttl_seconds` is escalated to `needs-attention.log`; at 2× it is terminated and
the claim released.

**Migrations in the runner:** a migration PR is human-gated unless the env is in `allowed_envs`
and has a command; with no reachable DB, declare `commands.<env> = "-"` (pipeline applies it) or
the gate can never pass.
