---
name: "cron-self-management"
description: "Use when an agent owns a cron and needs to read its own job id, disable a no-longer-useful cron, or remove one permanently. The default state: agents that created a cron cannot disable it without operator intervention, because their session's tool surface may not include cron management. This skill teaches the read-own-id, disable, and remove procedures plus the --tools flag that makes them available. For cron creation, see scripts/cron/cron-add.sh (PR #1423)."
license: GPL-3.0
domain: self-improvement
consumers:
  - daroja-coding-agent
  - dev_nexus
  - linux_desktop_seed
related_skills:
  - cron-trigger-pattern
  - cron-failure-recovery
---

# Cron Self-Management

If your agent authored a cron job, it should be able to manage that job without operator intervention: read its own id, disable when the cost is net-negative, remove when the job is permanently wrong. Today this requires the `cron` tool in your session's tool surface AND a known job id. This skill gives you both.

## Creation is the cron-job-kit's job, not this skill's

This skill owns **post-creation management** (read, disable, remove). For **creation**, see:

- `scripts/cron/cron-add.sh` (DarojaAI/linux-desktop-seed PR #1423) — JSON-spec wrapper. Validates sessionTarget × payload.kind matrix, rejects naive ISO on schedule.at, requires trigger.script on every-N jobs, gates sub-minute polling, requires failureAlert or cleanup block on persistent jobs, and reads back the created job via `cron get` to detect drift.
- `docs/cron-job-spec.md` — input contract, validation gates, exit codes.

The wrapper bakes in the cleanup policy this skill's disable/remove procedures protect against (a job without `failureAlert` or `cleanup` block is rejected at creation time). Use the wrapper; don't bypass it.

## When to load

- Session-startup if `cron list` shows any job whose `agentId` matches yours and `lastRunStatus == "ok"` but the cadence/cost looks wrong.
- On operator prompt like "the cron is too noisy" / "stop polling" / "kill that job."
- On any inbound `⚠️ Cron job ... failed` notice — hand off the failure-recovery diagnosis to `cron-failure-recovery`, then return here to disable the offender if appropriate.
- Never on healthy cron runs. Don't poll your own cron in normal agent turns; that defeats the trigger pattern's cost benefit.

## Procedure

### Step 1 — Read your own job id

```bash
openclaw cron list --json | \
  python3 -c '
import json, sys
d = json.load(sys.stdin)
mine = [j for j in d.get("jobs", []) if j.get("agentId") == "dev_nexus"]
for j in mine:
  print(f"{j[\"id\"]}  {j[\"name\"]}  schedule={j[\"schedule\"]}  enabled={j[\"enabled\"]}  lastRunStatus={j.get(\"state\",{}).get(\"lastRunStatus\")}")
'
```

If you don't know your agent id, run `openclaw agents list` and find yourself. The id is in `agents.list[i].id` for the agent block that owns your session.

### Step 2 — Disable vs remove

| Action | When | Reversible? |
|---|---|---|
| `disable` | Pause temporarily. Cadence is wrong but the job has signal value; you might re-enable later. | Yes (`enable <id>`) |
| `remove` / `rm` | Job is permanently wrong or superseded. | No (job id is gone; recreate with `add` if needed) |

Default to `disable` if unsure. Re-enabling a disabled job is one command; recreating a removed job requires recreating the full definition including the predicate script path, the agentTurn message, and the delivery target.

### Step 3 — Disable (the common case)

```bash
openclaw cron disable <job-id>
```

Idempotent. Re-running on an already-disabled job is a no-op (returns the same JSON shape with `enabled: false`). Exit code 0 means the job is now disabled and `nextRunAtMs` is gone. Exit code non-zero means the gateway didn't accept the change — read stderr verbatim, do not improvise.

Verify:

```bash
openclaw cron get <job-id>
```

The response must show `"enabled": false` and `state.nextRunAtMs` must be absent. If `nextRunAtMs` is still set, the disable didn't propagate; do not assume success.

**Verification rule (MEMORY #9, AGENTS.md):** Tool success messages are not verification. A `disable` call returning exit 0 is necessary but not sufficient. Confirm `cron get` shows `enabled: false` and `state.nextRunAtMs` absent before claiming the disable is live.

### Step 4 — Remove (permanent)

```bash
openclaw cron rm <job-id>
```

Idempotent. Re-running on an already-removed job exits non-zero with "not found" — that is fine, the goal state is achieved either way.

Removal deletes the job definition, runtime state, and run history. If you only want to preserve history, use `disable` instead. If you want to preserve the definition but clear history, the runtime does not expose that operation; use `disable` + manual SQLite pruning only if you understand the storage layout (`~/.openclaw/state/openclaw.sqlite`, table layout owned by the gateway).

### Step 5 — Self-disable on cost-novelty

This is the case that motivated this skill. If the cron you authored has been silent for 24h AND you wrote the message that says "if silent for 24h, disable yourself," do it on the next firing:

```
Run cron(action:"disable", jobId:"<id>") and exit with NO_REPLY.
```

Inside the agentTurn of a trigger-based cron, `cron` is in scope only if you authored the job with `--tools cron,exec,read` (or the agent's policy already grants `cron`). If you didn't, you cannot self-disable and the cron will keep firing until an operator intervenes. **Authoring the trigger-pattern cron without `--tools cron,...` is a bug.** See `cron-trigger-pattern` for the CLI shape.

## Tool-surface requirement

The `cron` tool family:

| Tool action | Purpose |
|---|---|
| `list` | Compact job summaries: `id`, `name`, `enabled`, `nextRunAtMs`, `scheduleKind`, `lastRunStatus`. |
| `get` | Full job definition including delivery, schedule, payload, run history. |
| `disable` | Pause without deletion. |
| `enable` | Resume a disabled job. |
| `rm` / `remove` | Permanent delete. |
| `runs` | Run history with `--id <job-id>`. |

`list` returns compact summaries. For delivery-route inspection, use `openclaw cron show <id>` from the CLI; the `cron` tool's `get` returns the stored job as JSON, not the resolved route.

If your session's tool surface doesn't include `cron`, you cannot self-manage crons. Two fixes:
- **Authoring fix:** add `cron` to `--tools` when authoring new crons. If you're using `scripts/cron/cron-add.sh`, set `toolsAllow: ["cron", "exec", "read"]` in the spec.
- **Policy fix:** add `cron` to the agent's `tools.allow` in `config/openclaw-ideal-config.json`. This is a structural change; ship as a PR, not a hot-patch.

## Acceptance criteria

- Self-disable latency (job firing → next agentTurn → `disable` → `nextRunAtMs` gone): ≤1 cron cycle.
- Zero fabricated disable attempts. Verify `cron get` shows `enabled: false` before reporting success.
- Never disable a cron you don't own. Filter by `agentId == <your-id>` from `cron list`.
- Self-disable only when the cron message itself instructs it, OR the operator explicitly asks. Don't autonomously disable crons for "efficiency" — that's a policy decision, not an agent one.

## Related

- `cron-trigger-pattern` — the cost-shape design that makes self-disable meaningful (without it, the cost is in the predicate script, not the model turn).
- `cron-failure-recovery` — Bucket A–E diagnosis for *failed* crons. If the cron is failing, hand off to that skill first, then return here to disable if appropriate.
- `scripts/cron/cron-add.sh` — the canonical creation path. Every cron this skill manages should have been created through the wrapper; verify via `cron get` that the spec survives a read-back round-trip if you didn't author it yourself.
