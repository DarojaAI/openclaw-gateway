#!/usr/bin/env python3
"""Cost Monitor for OpenCLAW.

Reads OpenClaw trajectory files (``~/.openclaw/agents/*/sessions/*.trajectory.jsonl``)
and produces per-agent, per-model cost and usage reports. Provides
``/cost-report`` and ``/context-health`` Discord slash commands (see
``config/skills/cost-report/SKILL.md`` and
``config/skills/context-health/SKILL.md``).

Data source
-----------
This module reads OpenClaw's trajectory files directly. Each
``model.completed`` event carries a ``data.usage`` block with
``input``, ``output``, ``cacheRead``, and ``cacheWrite`` token counts
plus the ``data.agentId`` and the ``modelId`` of the call. Cost is
computed using the per-model ``cost`` block in the gateway's
``config/openclaw-defaults.json`` (or the env-specific overlay).

This replaces the prior SQLite implementation, which depended on a
``log-call`` hook being invoked after every model call. The hook
was never wired in, so the database was always empty. Reading the
trajectory files directly is more robust: the data is the canonical
record OpenClaw writes regardless of gateway version, and it
survives gateway-restart cycles.

Compatibility
-------------
The public API is unchanged: ``handle_cost_report_command()``,
``handle_context_health_command()``, ``handle_model_cost_command()``,
``handle_model_usage_command()``, and the ``__main__`` CLI
subcommands (``cost-report``, ``context-health``, ``model-cost``,
``model-usage``). The deprecated ``init_db()``, ``log_api_call()``,
and ``log_compaction_event()`` functions are kept as no-ops so
external consumers that imported them don't break. They print a
deprecation warning to stderr on first call.

The CLI ``log-call`` and ``log-compaction`` subcommands remain as
no-ops with a deprecation message pointing at the trajectory files.
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

# Trajectory file location. Honors OPENCLAW_AGENTS_ROOT for test
# isolation; defaults to ~/.openclaw/agents.
AGENTS_ROOT = Path(
    os.environ.get("OPENCLAW_AGENTS_ROOT") or Path.home() / ".openclaw" / "agents"
)

# Gateway config location (for the per-model cost blocks). Honors
# OPENCLAW_GATEWAY_CONFIG for test isolation; defaults to the standard
# install path.
GATEWAY_CONFIG_PATH = Path(
    os.environ.get("OPENCLAW_GATEWAY_CONFIG")
    or Path.home() / ".openclaw" / "openclaw.json"
)

# Trajectory schema constants. The openclaw-trajectory schema is
# stable across OpenClaw versions; we tolerate additional event
# types and unknown fields.
TRAJECTORY_SCHEMA = "openclaw-trajectory"
MODEL_COMPLETED_EVENT = "model.completed"
CONTEXT_COMPILED_EVENT = "context.compiled"

# Per-million-token pricing conversion. OpenClaw's own cost
# resolver (session-cost-usage-2byiZUrq.js) treats cost.input /
# cost.output / cost.cacheRead / cost.cacheWrite as dollars per
# million tokens and divides the running token-weighted sum by 1e6
# to produce a dollar total. We follow the same convention so the
# gateway's monitor agrees with the runtime's own accounting.
#
# If the per-model cost block in openclaw-defaults.json or
# openclaw-test-vm.json has values that look like per-token rates
# (e.g. ``3e-07`` instead of ``0.3``), the report will be off by
# 1e6. That's a config bug, not a script bug — the values should
# be quoted in dollars per million tokens. The script does not try
# to detect or auto-correct this; it matches OpenClaw's formula
# exactly.
PER_MILLION = 1_000_000


# ── deprecation: kept for backward compat with old external consumers ──
_DB_PATH = Path.home() / ".openclaw" / "cost-log.db"
_DEPRECATION_WARNED = False


def _warn_deprecation(what: str) -> None:
    """Print a one-time deprecation warning to stderr.

    The trajectory file reader is the canonical data source; the
    SQLite DB the old API wrote to is no longer maintained. External
    callers should migrate to reading trajectory files (or invoke
    the CLI/handler functions on this module).
    """
    global _DEPRECATION_WARNED
    if _DEPRECATION_WARNED:
        return
    _DEPRECATION_WARNED = True
    print(
        f"[cost-monitor] DEPRECATION: {what} is a no-op. The cost "
        "monitor now reads OpenClaw trajectory files directly. See "
        "the module docstring for the new data source.",
        file=sys.stderr,
    )


def init_db() -> None:  # noqa: D401 — kept for API compat
    """No-op. Retained for backward compatibility with external consumers."""
    _warn_deprecation("init_db()")


def log_api_call(
    model: str,
    prompt_tokens: int,
    completion_tokens: int,
    cost_usd: float,
    agent_run_id: str | None = None,
) -> None:
    """No-op. Retained for backward compatibility; the runtime never wired this up."""
    _warn_deprecation("log_api_call()")


def log_compaction_event(
    reserved_tokens: int,
    used_tokens: int,
    agent_run_id: str | None = None,
) -> None:
    """No-op. Retained for backward compatibility; the runtime never wired this up."""
    _warn_deprecation("log_compaction_event()")


# ── cost resolver: per-model cost from the gateway's openclaw.json ──


def _load_cost_table(config_path: Path) -> dict[str, dict[str, float]]:
    """Load per-model pricing from the gateway's merged config.

    Returns a dict keyed by the full model id
    (e.g. ``openrouter/minimax/minimax-m2.7``) whose value is a
    dict with ``input``, ``output``, ``cacheRead``, ``cacheWrite``
    costs *per million tokens*. Missing values default to 0.

    Also indexes the same costs by the bare model name (the last
    ``/``-segment) and a case-insensitive variant, because the
    trajectory files record model IDs in inconsistent forms
    (``MiniMax-M2.7``, ``minimax/minimax-m2.7``, etc.). The lookup
    helper ``resolve_cost_block`` picks the best match.

    Tolerates a missing or unreadable config (returns an empty
    dict; the report will still show token counts, just no dollar
    amounts). Tolerates a non-dict ``cost`` block (treats it as
    zero-cost).
    """
    if not config_path.is_file():
        return {}
    try:
        with config_path.open("r", encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}

    cost_table: dict[str, dict[str, float]] = {}
    models = (
        cfg.get("models", {}).get("providers", {}).get("openrouter", {}).get("models", [])
    )
    for model in models:
        if not isinstance(model, dict):
            continue
        model_id = model.get("id")
        cost = model.get("cost") or {}
        if not isinstance(cost, dict):
            cost = {}
        if not model_id:
            continue
        block = {
            "input": float(cost.get("input") or 0),
            "output": float(cost.get("output") or 0),
            "cacheRead": float(cost.get("cacheRead") or 0),
            "cacheWrite": float(cost.get("cacheWrite") or 0),
        }
        # Index by the full id, the bare name, and lowercased variants
        # so trajectory file lookups hit even when the recorded
        # modelId is ``MiniMax-M2.7`` vs the config's
        # ``minimax/minimax-m2.7``.
        cost_table[model_id] = block
        bare = model_id.split("/")[-1]
        if bare and bare not in cost_table:
            cost_table[bare] = block
        lower = model_id.lower()
        if lower not in cost_table:
            cost_table[lower] = block
        bare_lower = bare.lower()
        if bare_lower not in cost_table:
            cost_table[bare_lower] = block
    return cost_table


def resolve_cost_block(
    model_id: str, cost_table: dict[str, dict[str, float]]
) -> dict[str, float] | None:
    """Look up a model in the cost table, tolerating naming variants.

    Tries (in order):
    1. Exact match on the recorded modelId
    2. Lowercased match
    3. Bare model name (last ``/``-segment), exact
    4. Bare model name, lowercased

    Returns the cost block (a dict with ``input``/``output``/
    ``cacheRead``/``cacheWrite`` keys) or None if no match. A
    matched block with all-zero values is still a hit (the
    model is known, just zero-priced) — callers should treat a
    None return as "unknown model" and a zero-block as "known but
    free."
    """
    if not model_id:
        return None
    for candidate in (
        model_id,
        model_id.lower(),
        model_id.split("/")[-1],
        model_id.split("/")[-1].lower(),
    ):
        if candidate and candidate in cost_table:
            return cost_table[candidate]
    return None


def _compute_cost(
    usage: dict[str, Any], cost_block: dict[str, float] | None
) -> float:
    """Compute the dollar cost of a single model.completed call.

    OpenClaw's runtime pre-computes the cost and writes it into
    ``data.usage.cost.total`` on each model.completed event. When
    that field is present (the common case), use it directly — it
    is the canonical value the runtime produced, and it accounts
    for any provider-specific quirks (tiered pricing, free tiers,
    reasoning-token billing, etc.) that the formula below does
    not.

    When the precomputed cost is missing (older trajectory files,
    events from before the runtime started recording it), fall
    back to a per-token * cost_per_million formula using the
    gateway's per-model cost block. If the model is also missing
    from the cost table, the dollar amount is 0 and the token
    counts are still reported.
    """
    usage_cost = usage.get("cost") or {}
    if isinstance(usage_cost, dict):
        total = usage_cost.get("total")
        if total is not None:
            try:
                return float(total)
            except (TypeError, ValueError):
                pass
    if not cost_block:
        return 0.0
    input_tokens = int(usage.get("input") or 0)
    output_tokens = int(usage.get("output") or 0)
    cache_read = int(usage.get("cacheRead") or 0)
    cache_write = int(usage.get("cacheWrite") or 0)

    return (
        input_tokens * cost_block.get("input", 0) / PER_MILLION
        + output_tokens * cost_block.get("output", 0) / PER_MILLION
        + cache_read * cost_block.get("cacheRead", 0) / PER_MILLION
        + cache_write * cost_block.get("cacheWrite", 0) / PER_MILLION
    )


# ── trajectory reader ──


def _agent_id_from_event(event: dict[str, Any]) -> str | None:
    """Recover the agent ID from a trajectory event.

    Tries (in order): ``data.agentId``, the second colon-delimited
    segment of ``sessionKey`` (format ``agent:<id>:...``). Returns
    None if neither is present (the event cannot be attributed).
    """
    data = event.get("data") or {}
    agent_id = data.get("agentId")
    if agent_id:
        return str(agent_id)
    session_key = event.get("sessionKey") or ""
    parts = session_key.split(":")
    if len(parts) >= 2 and parts[0] == "agent" and parts[1]:
        return parts[1]
    return None


def _within_days(event: dict[str, Any], cutoff: datetime) -> bool:
    """Return True if the event timestamp is on or after the cutoff."""
    ts = event.get("ts")
    if not ts:
        return True
    try:
        when = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return True
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when >= cutoff


def iter_model_completed(
    agents_root: Path,
    days: int | None = None,
):
    """Yield ``(agent_id, model_id, usage, ts)`` for each model.completed event.

    Tolerates:
    - Truncated tail lines (skipped, scan continues)
    - Unknown event types (skipped)
    - Missing data.usage block (yields zero-token usage, not an error)
    - Missing agents root (yields nothing; caller handles empty)
    - Non-Trajectory files (we just skip them by glob pattern)
    """
    if not agents_root.is_dir():
        return

    cutoff = None
    if days is not None and days > 0:
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)

    for traj in sorted(agents_root.glob("*/sessions/*.trajectory.jsonl")):
        try:
            with traj.open("r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if event.get("type") != MODEL_COMPLETED_EVENT:
                        continue
                    if cutoff is not None and not _within_days(event, cutoff):
                        continue
                    agent_id = _agent_id_from_event(event)
                    if not agent_id:
                        continue
                    model_id = event.get("modelId") or "unknown"
                    usage = (event.get("data") or {}).get("usage") or {}
                    yield agent_id, model_id, usage, event.get("ts", "")
        except OSError:
            # Permission denied or file vanished between glob and open.
            continue


def iter_context_compilations(
    agents_root: Path,
    days: int | None = None,
):
    """Yield ``(agent_id, reserved_tokens, used_tokens, ts)`` for each context.compiled event.

    Used by the context-health report. Reserved tokens are surfaced
    via the promptCache.lastCallUsage.total field; used tokens come
    from the same source. If the field is missing, both default to 0.
    """
    if not agents_root.is_dir():
        return

    cutoff = None
    if days is not None and days > 0:
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)

    for traj in sorted(agents_root.glob("*/sessions/*.trajectory.jsonl")):
        try:
            with traj.open("r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if event.get("type") != CONTEXT_COMPILED_EVENT:
                        continue
                    if cutoff is not None and not _within_days(event, cutoff):
                        continue
                    agent_id = _agent_id_from_event(event)
                    if not agent_id:
                        continue
                    data = event.get("data") or {}
                    last_call = (
                        data.get("promptCache", {}).get("lastCallUsage", {}) or {}
                    )
                    reserved = int(last_call.get("total") or 0)
                    used = int(
                        (data.get("usage") or {}).get("input", 0)
                        if data.get("usage")
                        else (last_call.get("input") or 0)
                    )
                    yield agent_id, reserved, used, event.get("ts", "")
        except OSError:
            continue


# ── aggregation ──


def aggregate_by_agent_and_model(
    agents_root: Path = AGENTS_ROOT,
    days: int | None = None,
    config_path: Path = GATEWAY_CONFIG_PATH,
) -> dict[str, dict[str, Any]]:
    """Aggregate per-agent, per-model usage and cost from trajectory files.

    Returns a dict keyed by agent_id, whose value is a dict with:

    - ``total``: a summary dict with ``prompt_tokens``,
      ``completion_tokens``, ``cache_read_tokens``,
      ``cache_write_tokens``, ``cost_usd``, ``call_count``
    - ``by_model``: a dict keyed by model_id, each value the same
      shape as ``total`` but scoped to that model
    - ``last_call_ts``: the timestamp of the most recent model call

    If the gateway config has no entry for a model, its cost is
    reported as 0. Token counts are still reported.
    """
    cost_table = _load_cost_table(config_path)
    by_agent: dict[str, dict[str, Any]] = {}

    for agent_id, model_id, usage, ts in iter_model_completed(agents_root, days):
        cost = _compute_cost(usage, resolve_cost_block(model_id, cost_table))
        if agent_id not in by_agent:
            by_agent[agent_id] = {
                "total": _empty_totals(),
                "by_model": defaultdict(_empty_totals),
                "last_call_ts": None,
            }
        agent = by_agent[agent_id]
        _accumulate(agent["total"], usage, cost)
        _accumulate(agent["by_model"][model_id], usage, cost)
        if ts and (agent["last_call_ts"] is None or ts > agent["last_call_ts"]):
            agent["last_call_ts"] = ts

    # by_model is a defaultdict; convert to a regular dict for JSON
    # serialization friendliness.
    for agent in by_agent.values():
        agent["by_model"] = dict(agent["by_model"])
    return by_agent


def aggregate_compaction_events(
    agents_root: Path = AGENTS_ROOT,
    days: int | None = None,
) -> list[dict[str, Any]]:
    """Aggregate context.compiled events into a list of recent compactions.

    Returns a list of dicts, most-recent first, with ``agent_id``,
    ``reserved_tokens``, ``used_tokens``, ``ratio`` (used/reserved,
    0 if reserved is 0), and ``ts``.
    """
    rows: list[dict[str, Any]] = []
    for agent_id, reserved, used, ts in iter_context_compilations(agents_root, days):
        ratio = used / reserved if reserved > 0 else 0
        rows.append(
            {
                "agent_id": agent_id,
                "reserved_tokens": reserved,
                "used_tokens": used,
                "ratio": ratio,
                "ts": ts,
            }
        )
    rows.sort(key=lambda r: r["ts"], reverse=True)
    return rows


def _empty_totals() -> dict[str, Any]:
    return {
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "cache_read_tokens": 0,
        "cache_write_tokens": 0,
        "cost_usd": 0.0,
        "call_count": 0,
    }


def _accumulate(target: dict[str, Any], usage: dict[str, Any], cost: float) -> None:
    target["prompt_tokens"] += int(usage.get("input") or 0)
    target["completion_tokens"] += int(usage.get("output") or 0)
    target["cache_read_tokens"] += int(usage.get("cacheRead") or 0)
    target["cache_write_tokens"] += int(usage.get("cacheWrite") or 0)
    target["cost_usd"] += cost
    target["call_count"] += 1


# ── formatting helpers ──


def format_ascii_bar(value: float, max_value: float, width: int = 20) -> str:
    """Format a value as an ASCII bar chart (for the report)."""
    if max_value == 0:
        return "[" + " " * width + "]"
    filled = int((value / max_value) * width)
    return "[" + "█" * filled + " " * (width - filled) + "]"


# ── Discord command handlers ──


def handle_cost_report_command(
    days: int = 7,
    agents_root: Path = AGENTS_ROOT,
    config_path: Path = GATEWAY_CONFIG_PATH,
) -> str:
    """Generate the /cost-report Discord message.

    Aggregates per-agent and per-model usage and cost for the last
    ``days`` days (default 7). The report includes a per-agent
    total, a per-model breakdown, and the active agent count.
    """
    by_agent = aggregate_by_agent_and_model(agents_root, days, config_path)
    if not by_agent:
        return (
            "📊 **Cost Report**\n\n"
            f"No model.completed events in the last {days} days. "
            "If the gateway has been making calls, check that "
            "trajectory files exist at "
            "`~/.openclaw/agents/*/sessions/*.trajectory.jsonl`."
        )

    # Daily / weekly spend across all agents.
    daily_cost = 0.0
    weekly_cost = 0.0
    for agent in by_agent.values():
        weekly_cost += agent["total"]["cost_usd"]
    if days == 1:
        daily_cost = weekly_cost
    else:
        # Approximate daily cost by scaling the window. The trajectory
        # reader filters by day already, so this is exact for the
        # requested window.
        daily_cost = weekly_cost / days if days > 0 else weekly_cost

    # Top agents by cost.
    top_agents = sorted(
        by_agent.items(),
        key=lambda kv: kv[1]["total"]["cost_usd"],
        reverse=True,
    )[:5]
    max_agent_cost = max((a[1]["total"]["cost_usd"] for a in top_agents), default=1) or 1

    # Per-model breakdown (across all agents).
    model_totals: dict[str, dict[str, Any]] = defaultdict(_empty_totals)
    for agent in by_agent.values():
        for model_id, row in agent["by_model"].items():
            for k in (
                "prompt_tokens",
                "completion_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "cost_usd",
            ):
                model_totals[model_id][k] += row[k]
            model_totals[model_id]["call_count"] += row["call_count"]
    sorted_models = sorted(
        model_totals.items(), key=lambda kv: kv[1]["cost_usd"], reverse=True
    )
    max_model_cost = max((m[1]["cost_usd"] for m in sorted_models), default=1) or 1

    report = f"📊 **Cost Report** (Last {days} days)\n\n"
    report += f"**Active Agents:** {len(by_agent)}\n"
    report += f"**Total Spend (window):** ${weekly_cost:.4f}\n"
    if days > 1:
        report += f"**Avg Daily Spend:** ${daily_cost:.4f}\n"
    report += "\n"

    report += "**Top Agents by Spend:**\n"
    for agent_id, agent in top_agents:
        t = agent["total"]
        bar = format_ascii_bar(t["cost_usd"], max_agent_cost, 10)
        report += (
            f"  `{agent_id}` {bar} ${t['cost_usd']:.4f} "
            f"({t['call_count']} calls, {t['prompt_tokens']:,}→{t['completion_tokens']:,} tokens)\n"
        )
    report += "\n"

    report += "**By Model:**\n"
    for model_id, t in sorted_models:
        short = model_id.split("/")[-1][:20]
        bar = format_ascii_bar(t["cost_usd"], max_model_cost, 10)
        report += (
            f"  {short} {bar} ${t['cost_usd']:.4f} ({t['call_count']} calls)\n"
        )
    return report


def handle_context_health_command(
    runs: int = 10,
    days: int | None = None,
    agents_root: Path = AGENTS_ROOT,
) -> str:
    """Generate the /context-health Discord message.

    Reports the most recent ``runs`` context compilations (default
    10) with reserve-token usage ratios. Surfaces a warning if
    more than 3 of the most recent compilations exceeded 80% of
    their reserve, which is the heuristic the prior SQLite version
    used.
    """
    events = aggregate_compaction_events(agents_root, days)[:runs]
    if not events:
        return (
            "🧠 **Context Health**\n\n"
            f"No context.compiled events found. The gateway has not "
            "compiled any context windows in the tracked window."
        )

    high_ratio_count = sum(1 for e in events if e["ratio"] > 0.8)
    report = f"🧠 **Context Health** (Last {len(events)} compilations)\n\n"
    if high_ratio_count > 3:
        report += "⚠️ **Warning:** High reserve token usage detected (>80% in 3+ runs)\n"
        report += "Consider lowering `reserveTokens` or raising `maxHistoryShare`\n\n"

    report += "**Recent Compactions:**\n"
    for event in events:
        bar = format_ascii_bar(event["ratio"], 1.0, 15)
        status = "🟢" if event["ratio"] < 0.8 else "🟡" if event["ratio"] < 0.9 else "🔴"
        report += (
            f"  {status} `{event['agent_id']}` {bar} "
            f"{event['ratio']*100:.1f}% ({event['used_tokens']}/{event['reserved_tokens']})\n"
        )
    return report


def handle_model_cost_command(
    model_id: str,
    days: int = 7,
    agents_root: Path = AGENTS_ROOT,
    config_path: Path = GATEWAY_CONFIG_PATH,
) -> str:
    """Generate a per-model cost report (legacy CLI handler).

    Aggregates calls to ``model_id`` across all agents in the
    window. Backward-compatible with the old SQLite-based version.
    """
    by_agent = aggregate_by_agent_and_model(agents_root, days, config_path)
    totals = _empty_totals()
    for agent in by_agent.values():
        if model_id in agent["by_model"]:
            row = agent["by_model"][model_id]
            for k in (
                "prompt_tokens",
                "completion_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "cost_usd",
            ):
                totals[k] += row[k]
            totals["call_count"] += row["call_count"]

    if totals["call_count"] == 0:
        return f"📊 **Model Cost: {model_id}**\n\nNo data for last {days} days."

    avg = totals["cost_usd"] / totals["call_count"] if totals["call_count"] > 0 else 0
    report = f"📊 **Model Cost: {model_id}** (last {days} days)\n\n"
    report += f"**Total Cost:** ${totals['cost_usd']:.4f}\n"
    report += f"**Calls:** {totals['call_count']}\n"
    report += f"**Prompt Tokens:** {totals['prompt_tokens']:,}\n"
    report += f"**Completion Tokens:** {totals['completion_tokens']:,}\n"
    report += f"**Avg per Call:** ${avg:.4f}\n"
    return report


def handle_model_usage_command(
    model_id: str,
    days: int = 7,
    agents_root: Path = AGENTS_ROOT,
    config_path: Path = GATEWAY_CONFIG_PATH,
) -> str:
    """Generate a per-day usage breakdown for ``model_id``.

    Backward-compatible with the old SQLite-based version.
    """
    by_agent = aggregate_by_agent_and_model(agents_root, days, config_path)
    per_day: dict[str, dict[str, Any]] = defaultdict(_empty_totals)
    for agent in by_agent.values():
        if model_id in agent["by_model"]:
            row = agent["by_model"][model_id]
            # We don't have a per-day breakdown in the trajectory
            # reader's per-agent summary, so we fall back to
            # a "single row for the window" report. The per-day
            # detail is not recoverable from the existing aggregate
            # function without re-scanning; for now, return the
            # window totals. See tests/cost-monitor.bats for the
            # per-day test that documents this limitation.
            day = datetime.now(timezone.utc).date().isoformat()
            for k in (
                "prompt_tokens",
                "completion_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "cost_usd",
                "call_count",
            ):
                per_day[day][k] += row[k]

    if not any(per_day[d]["call_count"] for d in per_day):
        return f"📈 **Model Usage: {model_id}**\n\nNo data for last {days} days."

    max_calls = max((per_day[d]["call_count"] for d in per_day), default=1) or 1
    report = f"📈 **Model Usage: {model_id}** (last {days} days)\n\n"
    report += "**Daily Breakdown:**\n"
    for day in sorted(per_day.keys(), reverse=True):
        row = per_day[day]
        bar = format_ascii_bar(row["call_count"], max_calls, 10)
        total_tokens = (
            row["prompt_tokens"]
            + row["completion_tokens"]
            + row["cache_read_tokens"]
            + row["cache_write_tokens"]
        )
        report += (
            f"  {day} {bar} {row['call_count']} calls | "
            f"${row['cost_usd']:.4f} | {total_tokens:,} tokens\n"
        )

    total_cost = sum(per_day[d]["cost_usd"] for d in per_day)
    total_calls = sum(per_day[d]["call_count"] for d in per_day)
    report += f"\n**Total:** {total_calls} calls | ${total_cost:.4f}"
    return report


# ── CLI ──


def _print_cli_deprecation(what: str) -> None:
    print(
        f"[cost-monitor] DEPRECATION: '{what}' is a no-op. The cost "
        "monitor now reads OpenClaw trajectory files directly. See "
        "scripts/cost-monitor.py for the new data source.",
        file=sys.stderr,
    )


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "Usage: cost-monitor.py <command>\n"
            "Commands:\n"
            "  cost-report              Aggregate per-agent + per-model cost (Discord-ready)\n"
            "  context-health           Recent context.compiled events with reserve ratios\n"
            "  model-cost <id> [days]   Per-model cost across all agents\n"
            "  model-usage <id> [days]  Per-day per-model usage breakdown\n"
            "  log-call <...>           DEPRECATED no-op; trajectory files are the data source\n"
            "  log-compaction <...>     DEPRECATED no-op; trajectory files are the data source",
            file=sys.stderr,
        )
        return 1

    command = sys.argv[1]
    if command == "cost-report":
        days = int(sys.argv[2]) if len(sys.argv) > 2 else 7
        print(handle_cost_report_command(days=days))
    elif command == "context-health":
        days = int(sys.argv[2]) if len(sys.argv) > 2 else None
        print(handle_context_health_command(days=days))
    elif command == "model-cost":
        if len(sys.argv) < 3:
            print("Usage: cost-monitor.py model-cost <model_id> [days]", file=sys.stderr)
            return 1
        model_id = sys.argv[2]
        days = int(sys.argv[3]) if len(sys.argv) > 3 else 7
        print(handle_model_cost_command(model_id, days))
    elif command == "model-usage":
        if len(sys.argv) < 3:
            print("Usage: cost-monitor.py model-usage <model_id> [days]", file=sys.stderr)
            return 1
        model_id = sys.argv[2]
        days = int(sys.argv[3]) if len(sys.argv) > 3 else 7
        print(handle_model_usage_command(model_id, days))
    elif command == "log-call":
        _print_cli_deprecation("log-call")
        return 0
    elif command == "log-compaction":
        _print_cli_deprecation("log-compaction")
        return 0
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
