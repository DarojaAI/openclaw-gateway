#!/usr/bin/env python3
"""
Cost Monitor for OpenCLAW
Tracks API spend by model, agent, and time period.
Provides /cost-report and /context-health Discord commands.
"""

import sqlite3
import json
import os
from datetime import datetime, timedelta
from pathlib import Path

DB_PATH = Path.home() / ".openclaw" / "cost-log.db"

def init_db():
    """Initialize the cost tracking database."""
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute("""
        CREATE TABLE IF NOT EXISTS api_calls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            model TEXT NOT NULL,
            prompt_tokens INTEGER,
            completion_tokens INTEGER,
            cost_usd REAL,
            agent_run_id TEXT
        )
    """)

    cursor.execute("""
        CREATE TABLE IF NOT EXISTS compaction_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            reserved_tokens INTEGER,
            used_tokens INTEGER,
            ratio REAL,
            agent_run_id TEXT
        )
    """)

    conn.commit()
    conn.close()

def log_api_call(model: str, prompt_tokens: int, completion_tokens: int,
                 cost_usd: float, agent_run_id: str = None):
    """Log an API call to the database."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute("""
        INSERT INTO api_calls (timestamp, model, prompt_tokens, completion_tokens, cost_usd, agent_run_id)
        VALUES (?, ?, ?, ?, ?, ?)
    """, (datetime.now().isoformat(), model, prompt_tokens, completion_tokens, cost_usd, agent_run_id))

    conn.commit()
    conn.close()

def log_compaction_event(reserved_tokens: int, used_tokens: int, agent_run_id: str = None):
    """Log a context compaction event."""
    ratio = used_tokens / reserved_tokens if reserved_tokens > 0 else 0

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute("""
        INSERT INTO compaction_events (timestamp, reserved_tokens, used_tokens, ratio, agent_run_id)
        VALUES (?, ?, ?, ?, ?)
    """, (datetime.now().isoformat(), reserved_tokens, used_tokens, ratio, agent_run_id))

    conn.commit()
    conn.close()

def get_daily_spend(days: int = 1) -> float:
    """Get total spend for the last N days."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cutoff = (datetime.now() - timedelta(days=days)).isoformat()
    cursor.execute("SELECT COALESCE(SUM(cost_usd), 0) FROM api_calls WHERE timestamp >= ?", (cutoff,))
    total = cursor.fetchone()[0]

    conn.close()
    return total

def get_weekly_spend() -> float:
    """Get total spend for the last 7 days."""
    return get_daily_spend(7)

def get_top_runs(days: int = 7, limit: int = 3):
    """Get top N most expensive runs in the last N days."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cutoff = (datetime.now() - timedelta(days=days)).isoformat()
    cursor.execute("""
        SELECT agent_run_id, SUM(cost_usd) as total_cost, COUNT(*) as call_count
        FROM api_calls
        WHERE timestamp >= ? AND agent_run_id IS NOT NULL
        GROUP BY agent_run_id
        ORDER BY total_cost DESC
        LIMIT ?
    """, (cutoff, limit))

    results = cursor.fetchall()
    conn.close()
    return results

def get_model_breakdown(days: int = 7):
    """Get spend breakdown by model."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cutoff = (datetime.now() - timedelta(days=days)).isoformat()
    cursor.execute("""
        SELECT model, SUM(cost_usd) as total_cost, COUNT(*) as call_count,
               SUM(prompt_tokens) as total_prompt, SUM(completion_tokens) as total_completion
        FROM api_calls
        WHERE timestamp >= ?
        GROUP BY model
        ORDER BY total_cost DESC
    """, (cutoff,))

    results = cursor.fetchall()
    conn.close()
    return results

def get_context_health(runs: int = 10):
    """Get context efficiency metrics from recent compaction events."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute("""
        SELECT reserved_tokens, used_tokens, ratio, timestamp
        FROM compaction_events
        ORDER BY timestamp DESC
        LIMIT ?
    """, (runs,))

    results = cursor.fetchall()
    conn.close()
    return results

def format_ascii_bar(value: float, max_value: float, width: int = 20) -> str:
    """Format a value as an ASCII bar chart."""
    if max_value == 0:
        return "[" + " " * width + "]"

    filled = int((value / max_value) * width)
    return "[" + "█" * filled + " " * (width - filled) + "]"

def generate_cost_report() -> str:
    """Generate a cost report for Discord."""
    init_db()

    daily = get_daily_spend(1)
    weekly = get_weekly_spend()
    top_runs = get_top_runs(7, 3)
    model_breakdown = get_model_breakdown(7)

    if not model_breakdown:
        return "📊 **Cost Report**\n\nNo data yet. Run some agent tasks first!"

    # Find max for bar chart scaling
    max_cost = max(row[1] for row in model_breakdown) if model_breakdown else 1

    report = "📊 **Cost Report** (Last 7 days)\n\n"
    report += f"**Daily Spend:** ${daily:.4f}\n"
    report += f"**Weekly Spend:** ${weekly:.4f}\n\n"

    report += "**By Model:**\n"
    for model, cost, calls, prompt, completion in model_breakdown:
        model_short = model.split("/")[-1][:20]  # Shorten model name
        bar = format_ascii_bar(cost, max_cost, 10)
        report += f"  {model_short}: {bar} ${cost:.4f} ({calls} calls)\n"

    if top_runs:
        report += "\n**Top 3 Expensive Runs:**\n"
        for run_id, cost, calls in top_runs:
            run_short = run_id[:8] if run_id else "unknown"
            report += f"  `{run_short}`: ${cost:.4f} ({calls} calls)\n"

    return report

def generate_context_health() -> str:
    """Generate context health report for Discord."""
    init_db()

    events = get_context_health(10)

    if not events:
        return "🧠 **Context Health**\n\nNo compaction data yet. Run some long agent sessions!"

    report = "🧠 **Context Health** (Last 10 compactions)\n\n"

    high_ratio_count = sum(1 for _, _, ratio, _ in events if ratio > 0.8)

    if high_ratio_count > 3:
        report += "⚠️ **Warning:** High reserve token usage detected (>80% in 3+ runs)\n"
        report += "Consider lowering `reserveTokens` or raising `maxHistoryShare`\n\n"

    report += "**Recent Compactions:**\n"
    for reserved, used, ratio, timestamp in events:
        bar = format_ascii_bar(ratio, 1.0, 15)
        status = "🟢" if ratio < 0.8 else "🟡" if ratio < 0.9 else "🔴"
        report += f"  {status} {bar} {ratio*100:.1f}% ({used}/{reserved})\n"

    return report

# Discord command handlers
def handle_cost_report_command():
    """Handle /cost-report command."""
    return generate_cost_report()

def handle_context_health_command():
    """Handle /context-health command."""
    return generate_context_health()


def handle_model_cost_command(model_id: str, days: int = 7):
    """Handle /model-cost <model_id> command."""
    init_db()

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cutoff = (datetime.now() - timedelta(days=days)).isoformat()
    cursor.execute("""
        SELECT SUM(cost_usd), COUNT(*), SUM(prompt_tokens), SUM(completion_tokens)
        FROM api_calls
        WHERE model = ? AND timestamp >= ?
    """, (model_id, cutoff))

    row = cursor.fetchone()
    conn.close()

    if not row or not row[0]:
        return f"📊 **Model Cost: {model_id}**\n\nNo data for last {days} days."

    cost, calls, prompt, completion = row
    avg = cost / calls if calls > 0 else 0

    report = f"📊 **Model Cost: {model_id}** (last {days} days)\n\n"
    report += f"**Total Cost:** ${cost:.4f}\n"
    report += f"**Calls:** {calls}\n"
    report += f"**Prompt Tokens:** {prompt:,}\n"
    report += f"**Completion Tokens:** {completion:,}\n"
    report += f"**Avg per Call:** ${avg:.4f}\n"

    return report


def handle_model_usage_command(model_id: str, days: int = 7):
    """Handle /model-usage <model_id> command."""
    init_db()

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cutoff = (datetime.now() - timedelta(days=days)).isoformat()

    # Per-day breakdown
    cursor.execute("""
        SELECT date(timestamp) as day,
               SUM(cost_usd), COUNT(*), SUM(prompt_tokens), SUM(completion_tokens)
        FROM api_calls
        WHERE model = ? AND timestamp >= ?
        GROUP BY date(timestamp)
        ORDER BY day DESC
    """, (model_id, cutoff))

    rows = cursor.fetchall()
    conn.close()

    if not rows:
        return f"📈 **Model Usage: {model_id}**\n\nNo data for last {days} days."

    report = f"📈 **Model Usage: {model_id}** (last {days} days)\n\n"
    report += "**Daily Breakdown:**\n"

    max_calls = max(row[2] for row in rows) if rows else 1
    for day, cost, calls, prompt, completion in rows:
        bar = format_ascii_bar(calls, max_calls, 10)
        report += f"  {day} {bar} {calls} calls | ${cost:.4f} | {prompt + completion:,} tokens\n"

    total_cost = sum(row[1] for row in rows)
    total_calls = sum(row[2] for row in rows)
    report += f"\n**Total:** {total_calls} calls | ${total_cost:.4f}"

    return report
if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: cost-monitor.py <command>")
        print("Commands: cost-report, context-health, model-cost, model-usage, log-call, log-compaction")
        sys.exit(1)

    command = sys.argv[1]

    if command == "cost-report":
        print(handle_cost_report_command())
    elif command == "context-health":
        print(handle_context_health_command())
    elif command == "model-cost":
        # model-cost <model_id> [days]
        if len(sys.argv) < 3:
            print("Usage: cost-monitor.py model-cost <model_id> [days]")
            sys.exit(1)
        model_id = sys.argv[2]
        days = int(sys.argv[3]) if len(sys.argv) > 3 else 7
        print(handle_model_cost_command(model_id, days))
    elif command == "model-usage":
        # model-usage <model_id> [days]
        if len(sys.argv) < 3:
            print("Usage: cost-monitor.py model-usage <model_id> [days]")
            sys.exit(1)
        model_id = sys.argv[2]
        days = int(sys.argv[3]) if len(sys.argv) > 3 else 7
        print(handle_model_usage_command(model_id, days))
    elif command == "log-call":
        # log-call <model> <prompt_tokens> <completion_tokens> <cost_usd> [agent_run_id]
        if len(sys.argv) < 6:
            print("Usage: cost-monitor.py log-call <model> <prompt> <completion> <cost> [run_id]")
            sys.exit(1)
        log_api_call(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]),
                     sys.argv[6] if len(sys.argv) > 6 else None)
        print("API call logged")
    elif command == "log-compaction":
        # log-compaction <reserved_tokens> <used_tokens> [agent_run_id]
        if len(sys.argv) < 4:
            print("Usage: cost-monitor.py log-compaction <reserved> <used> [run_id]")
            sys.exit(1)
        log_compaction_event(int(sys.argv[2]), int(sys.argv[3]),
                             sys.argv[4] if len(sys.argv) > 4 else None)
        print("Compaction event logged")
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)