---
name: cost-report
description: Generate a per-agent + per-model cost and usage report for the last N days. Use when the user asks about API spend, token usage, "how much has this cost," or wants a breakdown by model or by agent. Reads the openclaw-trajectory files directly; works without the gateway's runtime writing any separate log.
---

# Cost Report

Generate a Discord-ready cost report aggregating per-agent and per-model spend across the most recent N days. Backed by OpenClaw's trajectory files (the canonical record the runtime writes), so the report works even if the gateway's runtime never invokes the older `log-call` hook.

## When to Use

- User asks "how much have we spent this week" / "what's our OpenRouter bill"
- User asks "which agent is using the most tokens"
- User asks "break down spend by model"
- User wants a per-day trend
- Any cost / usage / spend question that needs attribution to an agent or model

## How It Works

The script reads `${OPENCLAW_AGENTS_ROOT:-~/.openclaw/agents}/*/sessions/*.trajectory.jsonl` and sums the `data.usage` block on each `model.completed` event per agent and per model. The dollar cost is taken from `data.usage.cost.total` (pre-computed by the runtime); if that field is missing, the script falls back to per-model pricing in `~/.openclaw/openclaw.json`.

The report is Discord-formatted with ASCII bar charts so it renders inline in any channel. The `days` argument controls the window (default 7).

## Command

```bash
/usr/local/bin/openclaw-cost-monitor cost-report [days]
```

Examples:

- `cost-report` — last 7 days
- `cost-report 1` — last 24 hours
- `cost-report 30` — last month

## What It Returns

A Discord markdown message with:

- **Active Agents** — the count of distinct agents that made at least one model call in the window
- **Total Spend (window)** — the dollar sum across all agents and models
- **Avg Daily Spend** — the daily average for multi-day windows
- **Top Agents by Spend** — top 5 agents, with a 10-cell ASCII bar
- **By Model** — full per-model breakdown with 10-cell bars

If there is no data in the window, the script returns an informative "no model.completed events" message rather than empty output.

## Implementation Notes

- Token counts are always reported; dollar amounts may be zero if the per-model `cost` block is missing or the runtime didn't record `usage.cost.total`.
- The script's `OPENCLAW_AGENTS_ROOT` env var is honored for test isolation; the default is `~/.openclaw/agents`.
- The script's `OPENCLAW_GATEWAY_CONFIG` env var is honored to override the cost table lookup; the default is `~/.openclaw/openclaw.json`.
- The CLI also accepts `model-cost <model_id> [days]` and `model-usage <model_id> [days]` for per-model drill-downs.

## Related

- `scripts/cost-monitor.py` — the script that generates the report
- `context-health` skill — the per-agent context-compaction health report
- `model-management` skill — for changing which models are in use
