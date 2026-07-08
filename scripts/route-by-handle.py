#!/usr/bin/env python3
"""
Route a Discord @handle mention to the matching agent in agents.lock.toml.

Usage:
    echo '@linux-desktop-seed hello' | python3 scripts/route-by-handle.py
    python3 scripts/route-by-handle.py --message '@linux-desktop-seed hello'
    python3 scripts/route-by-handle.py --handle @linux-desktop-seed
    python3 scripts/route-by-handle.py --handle @linux-desktop-seed \
        --channel 1501612164098687087

The script reads agents.lock.toml from config/ (or a custom path) and
looks up the first @handle found in the input text.

If --channel is supplied, channel pinning is checked against the agent's
allowed_channels list (RFC #31 Phase 5, Issues #47/#48). Per-agent flags:
  - dry_run (default True)        — log violation, still emit decision
  - enforce_channel_pinning       — when True AND dry_run is False,
                                     block on violation (exit 4).

Exit codes:
    0  — known handle, JSON on stdout with routing decision
    1  — unknown handle or no handle found (stderr message)
    2  — TOML parse error or lockfile missing
    4  — channel pinning violation in enforcement mode (no stdout)

Output (JSON on stdout):
    {
      "handle": "@linux-desktop-seed",
      "slug": "linux-desktop-seed",
      "repo": "DarojaAI/linux-desktop-seed",
      "config_source": "https://...",
      "config_sha": "...",
      "channel_pinning": {           # present iff --channel was supplied
        "channel_id": "...",
        "allowed_channels": ["..."],
        "violation": false,
        "dry_run": true,
        "enforced": false
      }
    }

If a channel pinning violation occurs in dry-run mode, the routing
decision is still emitted (with channel_pinning.violation=True) and a
one-line CHANNEL_PINNING_VIOLATION record is logged to stderr.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Import shared TOML parser from _agents_lock.py
# ---------------------------------------------------------------------------
from _agents_lock import load_agents_lock  # noqa: F401 (re-exported)

# Channel pinning (RFC #31 Phase 5, Issues #47/#48)
from channel_pinning import (
    EXIT_CHANNEL_PINNING_VIOLATION,
    check_channel_pinning,
    log_violation,
)

# Quarantine check (RFC #31 Phase 6, Issue #49)
from quarantine import is_quarantined, get_quarantine_info

# ---------------------------------------------------------------------------
# Handle routing
# ---------------------------------------------------------------------------

# Match @handle (Discord mention format: @word-characters-hyphens)
HANDLE_RE = re.compile(r'@([A-Za-z0-9_\-]+)')


def find_handles(text: str) -> list[str]:
    """Extract all @handle mentions from text."""
    return HANDLE_RE.findall(text)


def route_by_handle(
    registry: dict[str, Any], handle: str
) -> tuple[str, dict[str, Any]] | None:
    """
    Look up an @handle in the registry and return (slug, agent) or None.
    The handle should be a bare slug (no @), e.g. 'linux-desktop-seed'.
    """
    agents = registry.get("agents", {})
    for slug, agent in agents.items():
        agent_handle = agent.get("handle", "")
        # agent_handle is like "@linux-desktop-seed"
        if agent_handle == f"@{handle}":
            return slug, agent
    return None


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(
        description="Route a Discord @handle to an agent in agents.lock.toml"
    )
    parser.add_argument(
        "--lockfile",
        default=None,
        help="Path to agents.lock.toml (default: config/agents.lock.toml)",
    )
    parser.add_argument(
        "--message",
        default=None,
        help="Message text to search for @handle (alternative to stdin)",
    )
    parser.add_argument(
        "--handle",
        default=None,
        help="A specific @handle to look up (bypasses message parsing)",
    )
    parser.add_argument(
        "--channel",
        default=None,
        help=(
            "Originating Discord channel snowflake ID. When supplied, "
            "channel pinning is checked against the agent's "
            "allowed_channels (RFC #31 Phase 5, #47/#48)."
        ),
    )
    args = parser.parse_args()

    # Determine lockfile path
    if args.lockfile:
        lockfile_path = Path(args.lockfile)
    else:
        script_dir = Path(__file__).resolve().parent
        repo_root = script_dir.parent
        lockfile_path = repo_root / "config" / "agents.lock.toml"

    # Load registry
    registry = load_agents_lock(lockfile_path)
    if not registry:
        print(
            f"ERROR: agents.lock.toml not found or empty: {lockfile_path}",
            file=sys.stderr,
        )
        raise SystemExit(2)

    # Get handles from input
    handles: list[str] = []
    if args.handle:
        # Normalize: strip leading @ if user provided it
        h = args.handle.lstrip("@")
        handles = [h]
    elif args.message:
        handles = find_handles(args.message)
    else:
        # Read from stdin
        text = sys.stdin.read()
        handles = find_handles(text)

    if not handles:
        print("ERROR: no @handle found in input", file=sys.stderr)
        raise SystemExit(1)

    # Route the first @handle found
    first_handle = handles[0]
    resolved = route_by_handle(registry, first_handle)

    if resolved is None:
        print(
            f"ERROR: unknown handle @{first_handle}", file=sys.stderr
        )
        raise SystemExit(1)

    slug, agent = resolved

    # Quarantine check (RFC #31 Phase 6, Issue #49)
    if is_quarantined(slug, lockfile_path):
        info = get_quarantine_info(slug, lockfile_path)
        reason = info.get("reason", "unknown") if info else "unknown"
        print(
            f"ERROR: agent @{first_handle} is quarantined: {reason}",
            file=sys.stderr,
        )
        raise SystemExit(1)

    # Build the base routing decision
    decision: dict[str, Any] = {
        "handle": agent.get("handle", ""),
        "slug": slug,
        "repo": agent.get("repo", ""),
        "config_source": agent.get("config_source", ""),
        "config_sha": agent.get("config_sha", ""),
    }

    # Channel pinning (RFC #31 Phase 5, Issues #47/#48)
    # Only do the check if --channel was supplied (back-compat with callers
    # that don't have channel context yet).
    if args.channel is not None and args.channel != "":
        pinning = check_channel_pinning(agent, args.channel)
        decision["channel_pinning"] = {
            "channel_id": pinning["channel_id"],
            "allowed_channels": pinning["allowed_channels"],
            "violation": pinning["violation"],
            "dry_run": pinning["dry_run"],
            "enforced": pinning["enforced"],
        }

        if pinning["violation"]:
            # Always log the violation (dry-run + enforcement both log).
            log_violation(agent.get("handle", ""), pinning)
            if pinning["enforced"]:
                # Enforcement mode: do NOT emit routing decision; exit 4.
                raise SystemExit(EXIT_CHANNEL_PINNING_VIOLATION)
            # else: dry-run — fall through, emit decision with violation=true
            # so the caller can see it in stdout.

    print(json.dumps(decision, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
