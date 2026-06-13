---
name: context-health
description: Report the most recent context compilations and their reserve-token usage ratios. Use when the user asks about context window pressure, compaction frequency, "are we hitting the reserve," or wants to debug context budget. Reads the openclaw-trajectory files directly.
---

# Context Health

Generate a Discord-ready context-health report aggregating the most recent `context.compiled` events across all agents. Surfaces reserve-token usage ratios so the operator can see if context windows are running tight (a leading indicator of degraded response quality and rising cost per call).

## When to Use

- User asks "are we hitting the context budget"
- User asks "how often is the agent compacting"
- User sees a degradation in response quality and wants to rule out context pressure
- User is tuning `agents.defaults.compaction.reserveTokens` or `maxHistoryShare` and wants data to back the change

## How It Works

The script reads `${OPENCLAW_AGENTS_ROOT:-~/.openclaw/agents}/*/sessions/*.trajectory.jsonl` and pulls each `context.compiled` event's `data.promptCache.lastCallUsage` (reserved/used tokens). Ratios above 80% are flagged yellow; above 90% are red. If more than 3 of the most recent compilations exceed 80%, the report adds a warning suggesting the operator lower `reserveTokens` or raise `maxHistoryShare`.

The report is Discord-formatted with ASCII bars and emoji status indicators. The `runs` argument controls how many of the most recent compilations to show (default 10).

## Command

```bash
/usr/local/bin/openclaw-cost-monitor context-health [runs]
```

Examples:

- `context-health` — last 10 compilations
- `context-health 20` — last 20 compilations
- `context-health 5` — last 5 compilations

## What It Returns

A Discord markdown message with:

- A summary line: how many compilations were aggregated
- A warning if 3+ of the most recent compilations exceeded 80% reserve usage, with a hint about tuning
- A per-compaction list with: agent ID, reserve usage bar, percentage, and absolute token counts (used / reserved)

If there are no `context.compiled` events with `promptCache.lastCallUsage` in the window, the script returns an informative message rather than empty output. (Older sessions or sessions where the runtime didn't record the cache field will show as no data; this is normal for sessions that never hit a cache miss.)

## Implementation Notes

- The script reads `promptCache.lastCallUsage` from each `context.compiled` event. If the runtime's recording shape changes, this skill will silently show no data; the trajectory schema bump would need a corresponding update here.
- The 80% / 90% thresholds match the prior SQLite-based implementation's thresholds. Changing them is a one-line edit in `scripts/cost-monitor.py:handle_context_health_command`.
- Emoji status: 🟢 < 80%, 🟡 80-90%, 🔴 > 90%.

## Related

- `scripts/cost-monitor.py` — the script that generates the report
- `cost-report` skill — the per-agent + per-model cost report
- `agents.defaults.compaction.{reserveTokens, maxHistoryShare, mode}` — the knobs this report informs
