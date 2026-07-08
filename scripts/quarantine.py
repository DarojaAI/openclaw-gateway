#!/usr/bin/env python3
"""
Quarantine state management for agent health monitoring (RFC #31 Phase 6, Issue #49).

Quarantine state is stored in a JSON file. Each quarantined agent is recorded
with a timestamp, reason, and expiry (if applicable).

Usage:
    python3 scripts/quarantine.py --status linux-desktop-seed
    python3 scripts/quarantine.py --quarantine linux-desktop-seed --reason "heartbeat missed"
    python3 scripts/quarantine.py --unquarantine linux-desktop-seed
    python3 scripts/quarantine.py --list
    python3 scripts/quarantine.py --is-quarantined linux-desktop-seed

Exit codes:
    0  — operation succeeded
    1  — agent not found or operation failed
    2  — quarantine store error

Refs:
    DarojaAI/openclaw-gateway#49 (RFC #31 Phase 6, Health monitoring)
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Quarantine store
# ---------------------------------------------------------------------------

DEFAULT_QUARANTINE_STORE = "config/quarantine.json"


def _quarantine_store_path(lockfile_path: Path | None = None) -> Path:
    """Return the quarantine store path. Uses the same directory as the lockfile."""
    if lockfile_path is not None:
        return lockfile_path.parent / "quarantine.json"
    return Path(DEFAULT_QUARANTINE_STORE)


def _load_quarantine(path: Path) -> dict[str, Any]:
    """Load quarantine state from JSON file."""
    if not path.exists():
        return {"quarantined_agents": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if "quarantined_agents" not in data:
            data["quarantined_agents"] = {}
        return data
    except (json.JSONDecodeError, OSError):
        return {"quarantined_agents": {}}


def _save_quarantine(path: Path, data: dict[str, Any]) -> None:
    """Save quarantine state to JSON file."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot write quarantine store: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


def is_quarantined(agent_slug: str, lockfile_path: Path | None = None) -> bool:
    """Check if an agent is currently quarantined."""
    path = _quarantine_store_path(lockfile_path)
    store = _load_quarantine(path)
    entry = store["quarantined_agents"].get(agent_slug)
    if entry is None:
        return False
    # Check expiry if present
    expires_at = entry.get("expires_at")
    if expires_at is not None:
        try:
            expiry = datetime.fromisoformat(expires_at)
            if datetime.now(timezone.utc) > expiry:
                return False
        except ValueError:
            pass
    return True


def get_quarantine_info(agent_slug: str, lockfile_path: Path | None = None) -> dict[str, Any] | None:
    """Return quarantine info for an agent, or None if not quarantined."""
    path = _quarantine_store_path(lockfile_path)
    store = _load_quarantine(path)
    return store["quarantined_agents"].get(agent_slug)


def quarantine_agent(agent_slug: str, reason: str, lockfile_path: Path | None = None) -> None:
    """Mark an agent as quarantined."""
    path = _quarantine_store_path(lockfile_path)
    store = _load_quarantine(path)
    now = datetime.now(timezone.utc).isoformat()
    store["quarantined_agents"][agent_slug] = {
        "reason": reason,
        "quarantined_at": now,
        "expires_at": None,
        "status": "quarantined",
    }
    _save_quarantine(path, store)


def unquarantine_agent(agent_slug: str, lockfile_path: Path | None = None) -> None:
    """Remove an agent from quarantine."""
    path = _quarantine_store_path(lockfile_path)
    store = _load_quarantine(path)
    if agent_slug in store["quarantined_agents"]:
        del store["quarantined_agents"][agent_slug]
        _save_quarantine(path, store)


def list_quarantined(lockfile_path: Path | None = None) -> dict[str, Any]:
    """List all quarantined agents."""
    path = _quarantine_store_path(lockfile_path)
    store = _load_quarantine(path)
    return store["quarantined_agents"]


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Quarantine state management for agent health")
    parser.add_argument("--lockfile", default=None, help="Path to agents.lock.toml")
    parser.add_argument("--quarantine", default=None, help="Agent slug to quarantine")
    parser.add_argument("--unquarantine", default=None, help="Agent slug to unquarantine")
    parser.add_argument("--list", action="store_true", help="List all quarantined agents")
    parser.add_argument("--is-quarantined", default=None, help="Check if agent is quarantined")
    parser.add_argument("--status", default=None, help="Show quarantine status for agent")
    parser.add_argument("--reason", default="heartbeat missed", help="Reason for quarantine")
    args = parser.parse_args()

    lockfile_path = Path(args.lockfile) if args.lockfile else None

    if args.list:
        agents = list_quarantined(lockfile_path)
        if not agents:
            print("No agents quarantined.")
            return 0
        for slug, info in agents.items():
            print(f"  {slug}: {info.get('reason', 'unknown')} (quarantined at {info.get('quarantined_at', 'unknown')})")
        return 0

    if args.is_quarantined:
        if is_quarantined(args.is_quarantined, lockfile_path):
            print(f"Agent {args.is_quarantined} is quarantined.")
            return 0
        else:
            print(f"Agent {args.is_quarantined} is not quarantined.")
            return 1

    if args.quarantine:
        quarantine_agent(args.quarantine, args.reason, lockfile_path)
        print(f"Agent {args.quarantine} quarantined: {args.reason}")
        return 0

    if args.unquarantine:
        unquarantine_agent(args.unquarantine, lockfile_path)
        print(f"Agent {args.unquarantine} unquarantined.")
        return 0

    if args.status:
        info = get_quarantine_info(args.status, lockfile_path)
        if info:
            print(json.dumps(info, indent=2))
        else:
            print(f"Agent {args.status} is not quarantined.")
        return 0

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
