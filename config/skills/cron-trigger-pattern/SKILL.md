---
name: "cron-trigger-pattern"
description: "Use when designing an OpenClaw cron that needs to detect state changes cheaply without burning model tokens on every tick. The pattern: cheap JS predicate script owns the polling; model-backed agentTurn runs only when the predicate returns fire:true. Replaces the default 'every N + agentTurn' shape that costs tokens whether anything changed or not. For cron creation, see scripts/cron/cron-add.sh (PR #1423)."
license: GPL-3.0
domain: automation
consumers:
  - daroja-coding-agent
  - dev_nexus
  - linux_desktop_seed
related_skills:
  - cron-self-management
  - cron-failure-recovery
  - pr-watcher
---

# Cron Trigger Pattern

The default cron shape — `--every N + agentTurn` — calls the model on every tick. When most ticks have no real signal, that is pure waste. The trigger pattern flips the shape: a headless JS predicate script owns the polling (cheap, ≤5 tool calls, ≤30s budget per evaluation); the model-backed `agentTurn` runs only when the predicate returns `fire: true`. `fire: false` produces no run history, no model call, no Discord ping.

Use this when:
- Polling cadence is fast (≥30s) and most polls return "nothing changed."
- The signal is a deterministic diff (PR CI state, deploy status, file presence, log line).
- Cost-per-tick matters: a model turn on every poll burns tokens whether or not anything happened.

Don't use this when:
- Each tick has unique signal that needs narration (use the default shape).
- The signal can't be expressed as a JS read-only predicate (use the default shape).
- You need ≤30s cadence — the runtime floor is 30s and most uses don't need it.

## Creation path: use `scripts/cron/cron-add.sh`, not bare `cron add`

This skill describes the *shape* of trigger-pattern crons. For actual creation, use the structural wrapper in `DarojaAI/linux-desktop-seed` (PR #1423):

- `scripts/cron/cron-add.sh --spec path/to/spec.json` — enforces schema gates (sessionTarget × payload.kind matrix, naive-ISO rejection, trigger.script requirement on every-N jobs, sub-minute polling gate, failureAlert-or-cleanup policy), then reads back via `cron get` to detect drift.
- `docs/cron-job-spec.md` — input contract.
- `tests/cron-add.bats` — 14-test regression suite.

Spec shape for a trigger-pattern cron:

```json
{
  "name": "pr-watcher",
  "description": "Fire when PR #N CI state changes",
  "sessionTarget": "isolated",
  "schedule": { "kind": "every", "everyMs": 60000 },
  "trigger": { "script": "/* predicate */" },
  "payload": {
    "kind": "agentTurn",
    "message": "PR CI changed. Read ~/.openclaw/pr-watch.log + trigger message."
  },
  "cleanup": { "kind": "when_idle", "idleMs": 86400000 },
  "failureAlert": { "after": 5, "mode": "announce" }
}
```

Pass `trigger.script` in the spec; the wrapper will not silently accept an every-N job without one. If you don't have a predicate yet, the wrapper will tell you to write one.

## Contract (from `/usr/lib/node_modules/openclaw/docs/automation/cron-jobs.md:91-125`)

| Field | Constraint |
|---|---|
| Schedule | `every` or `cron` (not `at` — one-shots don't need a predicate) |
| `--every` lower bound | `cron.triggers.minIntervalMs`, default 30s |
| Trigger script return | `{ fire: bool, message?: string, state?: object }` |
| State persistence | `trigger.state` available at next eval (deeply frozen, 16 KB cap) |
| Wall-clock per eval | ≤30s |
| Tool calls per eval | ≤5 |
| Trust warning | Agent-authored scripts run with the agent's **full tool policy, including `exec`**. Treat as unattended code execution. |

`fire: false` persists evaluation state and counters, then reschedules without creating run history. `fire: true` appends `message` to the agent's system event and runs the `agentTurn` payload.

## CLI shape

```bash
openclaw cron add \
  --name "<name>" \
  --every 60s \
  --trigger-script /abs/path/to/predicate.js \
  --message "Investigate: <what to do when fire:true>" \
  --session isolated \
  --agent <agent-id> \
  --tools cron,exec,read \
  --announce \
  --channel discord \
  --to "channel:<id>"
```

`--tools cron,exec,read` is the floor for any self-managing cron. `cron` so the agentTurn can disable/rm itself; `exec` so the predicate's helpers (gh, jq) work; `read` so the agentTurn can inspect log/state.

**Verification rule (MEMORY #9, AGENTS.md):** Tool success messages are not verification. After `cron add` returns `ok`, call `cron get <job-id>` and confirm the stored job matches your intended spec (schedule, payload, tools, delivery). For structural enforcement of this read-back, use `scripts/cron/cron-add.sh` — it does the read-back for you and rolls back on drift.

## Worked example: PR CI watcher

Predicate script (`scripts/cron/pr-watcher-trigger.js`):

```js
// Read PR #N's CI status; fire only on state change.
const PR_NUMBER = process.env.PR_NUMBER ?? "1435";
const REPO = process.env.REPO ?? "DarojaAI/dev-nexus";

const res = await tools.call("exec", {
  command: `gh pr checks ${PR_NUMBER} --repo ${REPO} --json name,state -q '.[] | "\\(.name) \\(.state)"' | sort`,
});
const stdout = String(res?.result?.details?.aggregated ?? "").trim();
const sig = stdout; // whole sorted list is the signature

json({
  fire: sig !== trigger.state?.sig,
  message: `PR ${PR_NUMBER} CI changed: ${trigger.state?.sig ?? "unknown"} -> ${sig}`,
  state: { sig },
});
```

Cron spec (for `cron-add.sh`):

```json
{
  "name": "dev-nexus pr-watcher",
  "description": "Fire only when PR CI state changes; auto-disable after 24h idle",
  "sessionTarget": "isolated",
  "schedule": { "kind": "every", "everyMs": 60000 },
  "trigger": {
    "script": "/* contents of pr-watcher-trigger.js */"
  },
  "payload": {
    "kind": "agentTurn",
    "message": "PR CI changed. Read ~/.openclaw/pr-watch.log + the trigger message; post a one-line summary to the active Discord channel. If log has been silent for 24h, run cron(action:\"disable\", jobId:\"<this-job-id>\") and exit with NO_REPLY."
  },
  "cleanup": { "kind": "when_idle", "idleMs": 86400000 },
  "failureAlert": { "after": 5, "mode": "announce", "channel": "discord" }
}
```

## Gateway config requirement

`cron.triggers.enabled` must be true. Default is `false`. Edit `config/openclaw-ideal-config.json`:

```json5
cron: {
  triggers: {
    enabled: true,
    minIntervalMs: 30000,  // default floor; raise to 60000 for defensively slower cadence
  },
}
```

The doc warning (`cron-jobs.md:112`) is real: agents allowed to author cron jobs can run their trigger scripts with full tool policy. You're already at that trust bar if you let agents `cron add` model-backed runs.

## Predicate-script rules

1. **Read-only.** Writes belong in the agentTurn payload. If a fired run fails, the returned `state` is not persisted — the next eval sees the previous state and can fire again. So a write-in-predicate can double-fire.
2. **Single bool return.** `json({ fire, message?, state? })` is the only contract. Don't throw — return `{ fire: false, state: trigger.state }` on error so the eval doesn't poison counters.
3. **State ≤16 KB.** If your state shape grows past this, your signal isn't a state — it's a stream. Use a log file and a tail marker.
4. **≤5 tool calls.** If your predicate needs more, the work belongs in the agentTurn, not the predicate.
5. **≤30s wall-clock.** Same rule.

## Acceptance criteria

- Trigger-based cron: model token usage falls to near-zero on quiet days; fires on real state changes only.
- Predicate script lives in `scripts/cron/` under the owning repo, version-controlled, reviewed in PR.
- Single commit per cron addition. No bandaid tuning in follow-ups.
- Trust gate: `cron.triggers.enabled` flip is a PR with explicit warning in body, not a hot-patch.
- Cron was created through `scripts/cron/cron-add.sh` (verifiable via `cron get` showing the spec survived read-back).

## Related

- `cron-self-management` — disable/rm your own cron when the cadence is wrong or the cost is net-negative.
- `cron-failure-recovery` — if the cron breaks (Bucket A–E), hand off to that skill.
- `pr-watcher` (external repo, `DarojaAI/ai-governance`) — turn-anchored PR poll for active sessions. Trigger-based cron covers between-turn drift; turn-anchored poll covers active-session writes. Both together close the post-and-walk-away failure mode.
- `scripts/cron/cron-add.sh` (DarojaAI/linux-desktop-seed PR #1423) — the canonical creation path. Use the wrapper; the prompt-layer guidance in this skill is necessary but not sufficient.
