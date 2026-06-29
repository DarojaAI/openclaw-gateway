---
name: memory-status
description: Show the memory index status for every agent. Use when the user sends /memory-status, asks whether memory_search is healthy, suspects an index problem, or just wants a per-agent read on memory state. Surfaces the indexIdentity block (ok / missing / mismatch) and the active embedding provider/model so an operator can decide whether to rebuild.
commands:
  - name: memory-status
    description: Per-agent memory index status (identity, provider, chunk count)
---

# Memory Status

Show the per-agent memory index status so the user can see whether
`memory_search` is healthy, in a degraded state, or empty.

## When to use

- User says `/memory-status`
- User asks "is memory working" / "is memory_search broken" / "is the index healthy"
- User suspects the upstream memory index issue
  (`error: index metadata is missing`) and wants a per-agent report
- User wants to know which embedding provider/model is in use before deciding to rebuild

## Command

```bash
# All agents, machine-readable
openclaw memory status --json | python3 -m json.tool

# Or, the human-readable per-agent view
openclaw memory status
openclaw memory status --agent <agentId>

# JSON output of a single field
openclaw memory status --json | jq '.[].status.custom.indexIdentity'
```

If the user asked for a specific agent, pass `--agent <id>`. Otherwise
the global view is the default.

## What to report

Read `openclaw memory status --json` and produce a compact per-agent
table with these columns:

| Agent | Identity | Provider | Chunks | Notes |
|---|---|---|---|---|
| `main` | `ok` | `openai` | 42 | healthy |
| `linux_desktop_seed` | `missing` | `openai` | 0 | no data yet — first-use will rebuild |
| `coder` | `mismatch` | `openai` (requested `openrouter`) | 100 | **rebuild required** |

Source each column from:
- `agentId` → Agent
- `status.custom.indexIdentity.status` → Identity
- `status.provider` / `status.requestedProvider` → Provider
- `status.chunks` → Chunks
- `status.custom.indexIdentity.reason` → Notes (if present)

## Interpret the verdict

The status output mirrors the L3b deploy gate (`scripts/post-deploy-verify-memory-index.sh`):

| Identity | Data present? | Verdict | Action |
|---|---|---|---|
| `ok` | any | healthy | nothing to do |
| `missing` | no | fresh-install | nothing to do — first-use rebuilds |
| `missing` | yes | **regression** | run `/memory-rebuild` |
| `mismatch` | yes | **regression** | run `/memory-rebuild` |
| `missing` / `mismatch` | yes but `provider != requestedProvider` | model-swap signal | run `/memory-rebuild` after confirming the new provider is correct |
| any other value | any | unknown | surface to the user verbatim; do not auto-rebuild |

## If a rebuild is required

After presenting the status, if any agent is in a regression state,
suggest the recovery path:

```bash
openclaw memory index --force
```

Or from Discord, the `memory-rebuild` skill handles the same flow with
cleaner output.

## Forward-compat

The `indexIdentity.status` field may grow new values in upstream
`openclaw/openclaw` (the current values are `ok`, `missing`,
`mismatch`). Report any unrecognized value verbatim to the user rather
than guessing; do not auto-rebuild on unknown states.

## Related

- `memory-rebuild` skill — runs `openclaw memory index --force`
- `docs/troubleshooting/memory-index-disabled.md` — full diagnostic
  guide and the upstream race reference (#90361)
- `scripts/post-deploy-verify-memory-index.sh` — the deploy gate that
  catches regressions of the same shape
- `DarojaAI/openclaw-gateway#21` — original issue
