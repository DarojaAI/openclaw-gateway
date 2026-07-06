#!/usr/bin/env python3
"""
Capability-based dispatch for Discord messages routed to agents.

Extends the @handle routing (route-by-handle.py) to also resolve messages
by capability name when the @handle lookup misses.

Usage:
    python3 scripts/capability-dispatch.py --message '@vm-provision hello'
    python3 scripts/capability-dispatch.py --capability vm-provision
    python3 scripts/capability-dispatch.py --handle @linux-desktop-seed
    echo '@vm-provision hello' | python3 scripts/capability-dispatch.py

Exit codes:
    0  — routing decision on stdout (JSON)
    1  — unknown handle/capability or none found
    2  — TOML parse error or lockfile missing

Resolution order:
    1. @handle match (handle field in lockfile)
    2. @capability match (capabilities array in lockfile)
    3. Error

Output (JSON on stdout):
    {
      "handle": "@linux-desktop-seed",
      "matched_via": "capability",
      "match_type": "capability",
      "slug": "linux-desktop-seed",
      "repo": "DarojaAI/linux-desktop-seed",
      "config_source": "...",
      "config_sha": "...",
      "capabilities": ["vm-provision", "vm-decommission", "pr-stewardship"],
      "role": "executor"
    }

For --dry-run mode, the output is:
    {
      "would_route_to": { ... },
      "dry_run": true
    }
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
from _agents_lock import load_agents_lock

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
) -> dict[str, Any] | None:
    """
    Look up an @handle in the registry and return routing info, or None.
    The handle should be a bare slug (no @), e.g. 'linux-desktop-seed'.
    """
    agents = registry.get("agents", {})
    for slug, agent in agents.items():
        agent_handle = agent.get("handle", "")
        # agent_handle is like "@linux-desktop-seed"
        if agent_handle == f"@{handle}":
            return _build_routing_result(agent, slug, "handle", agent_handle)
    return None


# ---------------------------------------------------------------------------
# Capability routing
# ---------------------------------------------------------------------------


def route_by_capability(
    registry: dict[str, Any], capability: str
) -> dict[str, Any] | None:
    """
    Look up a capability name in the registry and return routing info, or None.
    Returns the first agent that has the capability.
    """
    agents = registry.get("agents", {})
    for slug, agent in agents.items():
        capabilities = agent.get("capabilities", [])
        if isinstance(capabilities, list) and capability in capabilities:
            agent_handle = agent.get("handle", "")
            return _build_routing_result(agent, slug, "capability", agent_handle)
    return None


def _build_routing_result(
    agent: dict[str, Any],
    slug: str,
    match_type: str,
    agent_handle: str,
) -> dict[str, Any]:
    """Build the routing decision JSON object."""
    return {
        "handle": agent_handle,
        "matched_via": match_type,
        "match_type": match_type,
        "slug": slug,
        "repo": agent.get("repo", ""),
        "config_source": agent.get("config_source", ""),
        "config_sha": agent.get("config_sha", ""),
        "capabilities": agent.get("capabilities", []),
        "role": agent.get("role", ""),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(
        description="Capability-based dispatch for Discord messages"
    )
    parser.add_argument(
        "--lockfile",
        default=None,
        help="Path to agents.lock.toml (default: config/agents.lock.toml)",
    )
    parser.add_argument(
        "--message",
        default=None,
        help="Message text to search for @handle or @capability (alternative to stdin)",
    )
    parser.add_argument(
        "--capability",
        default=None,
        help="A specific capability to look up (bypasses message parsing)",
    )
    parser.add_argument(
        "--handle",
        default=None,
        help="A specific @handle to look up (bypasses message parsing)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Log the routing decision but exit 0 with dry_run flag; do not emit a route decision",
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

    # Determine what to look up
    handle_to_lookup: str | None = None
    capability_to_lookup: str | None = None

    if args.handle:
        # --handle given: normalize by stripping leading @
        handle_to_lookup = args.handle.lstrip("@")
    elif args.capability:
        # --capability given: direct capability lookup
        capability_to_lookup = args.capability
    elif args.message:
        # Parse message for @handle or @capability
        tokens = find_handles(args.message)
        if tokens:
            first_token = tokens[0]
            # Try handle first
            result = route_by_handle(registry, first_token)
            if result is not None:
                handle_to_lookup = first_token
            else:
                # Fall through to capability lookup
                capability_to_lookup = first_token
    else:
        # Read from stdin
        text = sys.stdin.read()
        tokens = find_handles(text)
        if tokens:
            first_token = tokens[0]
            # Try handle first
            result = route_by_handle(registry, first_token)
            if result is not None:
                handle_to_lookup = first_token
            else:
                # Fall through to capability lookup
                capability_to_lookup = first_token

    # No tokens found at all
    if handle_to_lookup is None and capability_to_lookup is None:
        print("ERROR: no @handle or @capability found in input", file=sys.stderr)
        raise SystemExit(1)

    # Route
    result: dict[str, Any] | None = None
    if handle_to_lookup is not None:
        result = route_by_handle(registry, handle_to_lookup)
        if result is None:
            print(
                f"ERROR: unknown handle @{handle_to_lookup}",
                file=sys.stderr,
            )
            raise SystemExit(1)
    elif capability_to_lookup is not None:
        result = route_by_capability(registry, capability_to_lookup)
        if result is None:
            print(
                f"ERROR: no @handle or @capability matched",
                file=sys.stderr,
            )
            raise SystemExit(1)

    # Dry-run mode
    if args.dry_run:
        dry_result = {
            "would_route_to": result,
            "dry_run": True,
        }
        print(json.dumps(dry_result, indent=2))
        return 0

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
