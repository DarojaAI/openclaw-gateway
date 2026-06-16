---
name: model-preferences
description: "Manage model defaults for every role: main, backup, subagent, compaction, heartbeat, per-agent. Use when setting or showing model preferences for any slot."
---

# Model Preferences

Manage persistent model defaults for every role in OpenClaw: **main** (primary agent), **backup** (failover), **subagent** (spawned agents), **compaction** (context summarization), **heartbeat** (proactive checks), and **agent <id>** (per-agent overrides).

Preferences are stored in `~/.openclaw/model-preferences.json`. Each set also patches the live config so changes apply without restart where possible.

## Triggers

### Set a default
- `/set-defaults <role> <model>` where role is one of: `main`, `backup`, `subagent`, `compaction`, `heartbeat`
- `/set-defaults agent <agent_id> <model>` for a specific agent
- "set my backup model to kimi"
- "make claude-sonnet my main default"
- "use morph for compaction"
- "set heartbeat model to haiku"
- "set darojaai_architect to sonnet"

**Action by role:**

| Role | Live config path | Mechanism |
|------|------------------|-----------|
| `main` | `agents.defaults.model` | `openclaw-model-manager switch <model>` then update prefs |
| `backup` | prefs only (not a live config slot) | write prefs only |
| `subagent` | prefs only (read at spawn time) | write prefs only |
| `compaction` | `agents.defaults.compaction.model` | `gateway config.patch` hot-reload, write prefs |
| `heartbeat` | `agents.defaults.heartbeat.model` | `gateway config.patch` hot-reload, write prefs |
| `agent <id>` | `agents.list[i].model` | `gateway config.patch` hot-reload, write prefs |

Alias resolution: if user provides a short name like `kimi`, `m3`, `haiku`, or `coder`, resolve against `agents.defaults.models` aliases first, then `models.providers.openrouter.models[].id`. If unresolved, fail with a hint to run `/model <name>` first.

### Show all defaults
- `/model-defaults`
- `/get-defaults`
- "show my model defaults"
- "what models am I configured to use"

**Action:** Read `~/.openclaw/model-preferences.json`, merge with the live config (`gateway config.get agents.defaults.compaction.model`, `agents.defaults.heartbeat.model`, `agents.list[].model`), and print a unified table.

### Use a role's model right now (ephemeral)
- `/use-backup` → switch session to backup model
- `/compaction-model` → show current compaction model
- `/use-compaction <model>` → switch session to whatever the compaction model is, or set compaction model if name given
- "switch to backup model"
- "use my backup"
- "what model is compaction using"

**Action:** Read role from prefs → call `openclaw-model-manager switch <model>` for the session. Compaction itself is not switchable mid-session (it's used by the runtime, not the turn), but `/use-compaction <model>` will *set* the compaction model for the next compaction run.

### Use subagent model for a task
- `/subagent-model`
- "what model do subagents use"
- "spawn a coding agent with the subagent model"
- "/spawn-coding <task>"

**Action:** If followed by a task ("spawn a..."), read subagent model from prefs → `sessions_spawn(..., model="<subagent model>")`.

## Response Formatting

For `/model-defaults`, output a unified table:
```
Model Defaults:
  main       → openrouter/anthropic/claude-sonnet-4.5 (reasoning)
  backup     → openrouter/moonshotai/kimi-k2.6 (kimi)
  subagent   → openrouter/minimax/minimax-m2.7 (coding)
  compaction → openrouter/morph/morph-v3-fast (cheapest)
  heartbeat  → openrouter/anthropic/claude-haiku-4.5 (haiku)
  agent:linux_desktop_seed → openrouter/minimax/minimax-m3 (default)
  agent:darojaai_architect → openrouter/anthropic/claude-sonnet-4.5 (override)
```

For set confirmations:
```
✅ Compaction default set: morph
   Full ID: openrouter/morph/morph-v3-fast
   Live config patched (hot-reload, no restart)
```

For role reads:
```
📦 Compaction model: openrouter/morph/morph-v3-fast
   Set: 2026-06-15T02:42:00Z
   Change with: /set-defaults compaction <model>
```

## Preference File

`~/.openclaw/model-preferences.json` shape:
```json
{
  "main": "openrouter/anthropic/claude-sonnet-4.5",
  "backup": "openrouter/moonshotai/kimi-k2.6",
  "subagent": "openrouter/minimax/minimax-m2.7",
  "compaction": "openrouter/morph/morph-v3-fast",
  "heartbeat": "openrouter/anthropic/claude-haiku-4.5",
  "agents": {
    "linux_desktop_seed": "openrouter/minimax/minimax-m3",
    "darojaai_architect": "openrouter/anthropic/claude-sonnet-4.5"
  },
  "updatedAt": "2026-06-15T02:42:00Z"
}
```

Empty string for any role means "use system default" (no override). Agents object is sparse — only agents with overrides appear.

## Implementation Notes

- Use `openclaw-model-manager switch` for `main` (handles import + restart prompt).
- Use `gateway config.patch` for `compaction`, `heartbeat`, and `agent <id>` — these are hot-reload, no restart needed.
- Backup is prefs-only by design: OpenClaw's `agents.defaults.model.fallbacks` is what controls failover at runtime; the backup slot here is the user's "if I had to pick one to fall back to" preference.
- For `agent <id>`, look up the agent's index in `agents.list` from `gateway config.get agents.list` and patch the right entry. If agent id doesn't exist, fail with a list of valid agent ids.
- Always re-validate the live config after a patch: `gateway config.get` and check `issues: []`.
- Aliases are resolved against `agents.defaults.models` (the user-defined alias map) first, then `models.providers.*.models[].id`.
- If a set fails (config validation, missing model, unknown alias), leave the prefs file unchanged and surface the error.
- Stale prefs: if `model-preferences.json.main` differs from `gateway config.get agents.defaults.model`, warn the user — the live config is authoritative for the running session.
