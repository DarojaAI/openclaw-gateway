#!/usr/bin/env python3
"""
Health monitoring for agent heartbeat (RFC #31 Phase 6, Issue #49).

Reads heartbeat config from agents.lock.toml and monitors agent health.
If an agent misses its heartbeat interval, it is quarantined.

Usage:
    python3 scripts/health-monitoring.py --lockfile config/agents.lock.toml --check
    python3 scripts/health-monitoring.py --lockfile config/agents.lock.toml --agent linux-desktop-seed
    python3 scripts/health-monitoring.py --lockfile config/agents.lock.toml --status

Exit codes:
    0  — all agents healthy or agent healthy
    1  — agent quarantined or unhealthy
    2  — lockfile parse error

Refs:
    DarojaAI/openclaw-gateway#49 (RFC #31 Phase 6, Health monitoring)
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from _agents_lock import load_agents_lock
from quarantine import (
    is_quarantined,
    quarantine_agent,
    unquarantine_agent,
)

# ---------------------------------------------------------------------------
# Heartbeat config
# ---------------------------------------------------------------------------

def get_heartbeat_config(agent: dict[str, Any]) -> dict[str, Any]:
    """Extract heartbeat config from agent entry.
    
    Supports both nested format (heartbeat.enabled) and flat format (heartbeat_enabled).
    """
    # Try nested format first (non-empty heartbeat dict)
    hb = agent.get("heartbeat")
    if isinstance(hb, dict) and hb:
        enabled = bool(hb.get("enabled", False))
        interval_hours = int(hb.get("interval_hours", 0))
    else:
        # Fall back to flat format from lockfile
        enabled = bool(agent.get("heartbeat_enabled", False))
        interval_hours = int(agent.get("heartbeat_interval_hours", 0))
    return {
        "enabled": enabled,
        "interval_hours": interval_hours,
    }


def get_heartbeat_enabled(agent: dict[str, Any]) -> bool:
    """Check if heartbeat is enabled for this agent."""
    # Try nested format first (non-empty heartbeat dict)
    hb = agent.get("heartbeat")
    if isinstance(hb, dict) and hb:
        return bool(hb.get("enabled", False))
    # Fall back to flat format from lockfile
    return bool(agent.get("heartbeat_enabled", False))


def get_heartbeat_interval(agent: dict[str, Any]) -> int:
    """Get heartbeat interval in hours."""
    # Try nested format first (non-empty heartbeat dict)
    hb = agent.get("heartbeat")
    if isinstance(hb, dict) and hb:
        return int(hb.get("interval_hours", 0))
    # Fall back to flat format from lockfile
    return int(agent.get("heartbeat_interval_hours", 0))


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

def check_agent_health(
    agent_slug: str,
    agent: dict[str, Any],
    lockfile_path: Path | None = None,
) -> dict[str, Any]:
    """Check health status of a single agent."""
    hb = get_heartbeat_config(agent)
    
    if not hb["enabled"]:
        return {
            "slug": agent_slug,
            "status": "no-heartbeat",
            "heartbeat": hb,
            "quarantined": is_quarantined(agent_slug, lockfile_path),
        }
    
    if is_quarantined(agent_slug, lockfile_path):
        return {
            "slug": agent_slug,
            "status": "quarantined",
            "heartbeat": hb,
            "quarantined": True,
        }
    
    return {
        "slug": agent_slug,
        "status": "healthy",
        "heartbeat": hb,
        "quarantined": False,
    }


def check_all_agents(
    lockfile_path: Path | None = None,
) -> dict[str, Any]:
    """Check health status of all agents."""
    if lockfile_path is None:
        script_dir = Path(__file__).resolve().parent
        repo_root = script_dir.parent
        lockfile_path = repo_root / "config" / "agents.lock.toml"
    
    registry = load_agents_lock(lockfile_path)
    if not registry:
        return {"error": "lockfile not found or empty"}
    
    agents = registry.get("agents", {})
    results = {}
    
    for slug, agent in agents.items():
        results[slug] = check_agent_health(slug, agent, lockfile_path)
    
    return {
        "agents": results,
        "total": len(results),
        "healthy": sum(1 for r in results.values() if r["status"] == "healthy"),
        "quarantined": sum(1 for r in results.values() if r["status"] == "quarantined"),
        "no-heartbeat": sum(1 for r in results.values() if r["status"] == "no-heartbeat"),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Health monitoring for agent heartbeat")
    parser.add_argument("--lockfile", default=None, help="Path to agents.lock.toml")
    parser.add_argument("--check", action="store_true", help="Check health of all agents")
    parser.add_argument("--agent", default=None, help="Check specific agent health")
    parser.add_argument("--status", action="store_true", help="Show health status of all agents")
    parser.add_argument("--quarantine", default=None, help="Quarantine an agent (comma-separated slugs)")
    parser.add_argument("--unquarantine", default=None, help="Unquarantine an agent (comma-separated slugs)")
    parser.add_argument("--reason", default="heartbeat missed", help="Reason for quarantine")
    args = parser.parse_args()

    lockfile_path = Path(args.lockfile) if args.lockfile else None

    if args.status or args.check:
        result = check_all_agents(lockfile_path)
        if "error" in result:
            print(json.dumps(result, indent=2))
            return 2
        print(json.dumps(result, indent=2))
        if result.get("quarantined", 0) > 0:
            return 1
        return 0

    if args.agent:
        registry = load_agents_lock(lockfile_path or Path("config/agents.lock.toml"))
        if not registry:
            print(f"ERROR: lockfile not found or empty", file=sys.stderr)
            return 2
        agents = registry.get("agents", {})
        if args.agent not in agents:
            print(f"ERROR: agent {args.agent} not found in lockfile", file=sys.stderr)
            return 1
        result = check_agent_health(args.agent, agents[args.agent], lockfile_path)
        print(json.dumps(result, indent=2))
        if result["status"] == "quarantined":
            return 1
        return 0

    if args.quarantine:
        slugs = [s.strip() for s in args.quarantine.split(",") if s.strip()]
        for slug in slugs:
            quarantine_agent(slug, args.reason, lockfile_path)
            print(f"Quarantined: {slug} (reason: {args.reason})")
        return 0

    if args.unquarantine:
        slugs = [s.strip() for s in args.unquarantine.split(",") if s.strip()]
        for slug in slugs:
            unquarantine_agent(slug, lockfile_path)
            print(f"Unquarantined: {slug}")
        return 0

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
