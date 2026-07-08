#!/usr/bin/env python3
"""
Canary routing for agent dispatch (RFC #31 Phase 6, Issue #52).

When multiple agents match a capability or when an agent is marked as
a canary, this module selects which agent to route to based on a
configurable canary weight percentage (default 10%).

Usage (standalone):
    python3 scripts/canary_routing.py \
        --lockfile config/agents.lock.toml \
        --handle @linux-desktop-seed

    python3 scripts/canary_routing.py \
        --lockfile config/agents.lock.toml \
        --capability vm-provision

    python3 scripts/canary_routing.py \
        --lockfile config/agents.lock.toml \
        --handle @linux-desktop-seed \
        --canary-weight 20

    python3 scripts/canary_routing.py \
        --lockfile config/agents.lock.toml \
        --handle @linux-desktop-seed \
        --dry-run

    python3 scripts/canary_routing.py \
        --lockfile config/agents.lock.toml \
        --capability vm-provision \
        --seed 42

Exit codes:
    0  — routing decision on stdout (JSON)
    1  — unknown handle/capability or none found
    2  — TOML parse error or lockfile missing

Output (JSON on stdout):
    {
      "handle": "@linux-desktop-seed",
      "slug": "linux-desktop-seed",
      "repo": "DarojaAI/linux-desktop-seed",
      "config_source": "...",
      "config_sha": "...",
      "canary": {
        "is_canary": false,
        "canary_weight_percent": 10,
        "roll": 73,
        "selected": "linux-desktop-seed",
        "total_candidates": 1,
        "canary_candidates": 0,
        "stable_candidates": 1
      }
    }

For --dry-run mode, the output is:
    {
      "would_route_to": { ... },
      "dry_run": true
    }

Refs:
  DarojaAI/openclaw-gateway#52 (Phase 6 canary routing)
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Import shared TOML parser
# ---------------------------------------------------------------------------
from _agents_lock import load_agents_lock

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
EXIT_CHANNEL_PINNING_VIOLATION = 4  # reserved for future use

# ---------------------------------------------------------------------------
# Default canary weight (percentage)
# ---------------------------------------------------------------------------
DEFAULT_CANARY_WEIGHT = 10

# ---------------------------------------------------------------------------
# Canary routing logic
# ---------------------------------------------------------------------------


def get_canary_weight(agent: dict[str, Any]) -> int:
    """Return the canary weight percentage for an agent.

    Falls back to DEFAULT_CANARY_WEIGHT if not set.
    """
    val = agent.get("canary_weight_percent")
    if val is None:
        return DEFAULT_CANARY_WEIGHT
    try:
        return int(val)
    except (TypeError, ValueError):
        return DEFAULT_CANARY_WEIGHT


def is_canary(agent: dict[str, Any]) -> bool:
    """Return True if the agent is marked as a canary."""
    val = agent.get("canary")
    if val is None:
        return False
    return bool(val)


def select_canary_agent(
    registry: dict[str, Any],
    candidates: list[dict[str, Any]],
    canary_weight: int | None = None,
    seed: int | None = None,
) -> dict[str, Any]:
    """Given a list of candidate agents, select one based on canary config.

    The selection logic:
      1. Partition candidates into canary and stable sets
      2. If no canary agents exist, pick the first stable agent
      3. If canary agents exist, roll a random number 0-99
         - If roll < canary_weight (default 10): select a random canary agent
         - Else: select a random stable agent (or first if no stable agents)
      4. Log the decision

    Args:
        registry: The full lockfile registry (for context)
        candidates: List of agent dicts (from lockfile)
        canary_weight: Override canary weight percentage (default: use per-agent or DEFAULT_CANARY_WEIGHT)
        seed: Optional random seed for deterministic testing

    Returns:
        dict with selected agent info and canary metadata
    """
    if seed is not None:
        rng = random.Random(seed)
    else:
        rng = random.Random()

    canary_agents = [a for a in candidates if is_canary(a)]
    stable_agents = [a for a in candidates if not is_canary(a)]

    if not canary_agents and not stable_agents:
        raise ValueError("no candidate agents provided")

    # Determine effective canary weight
    # Use the first candidate's canary_weight_percent if not overridden
    if canary_weight is not None:
        effective_weight = canary_weight
    elif canary_agents:
        effective_weight = get_canary_weight(canary_agents[0])
    else:
        effective_weight = DEFAULT_CANARY_WEIGHT

    # Roll
    roll = rng.randint(0, 99)

    selected: dict[str, Any]
    selected_is_canary: bool

    if not canary_agents:
        # No canary agents → always stable
        selected = stable_agents[0]
        selected_is_canary = False
    elif roll < effective_weight:
        # Canary wins
        selected = rng.choice(canary_agents)
        selected_is_canary = True
    else:
        # Stable wins (fall back to first stable agent, or first candidate if no stable)
        if stable_agents:
            selected = stable_agents[0]
        else:
            selected = canary_agents[0]
        selected_is_canary = False

    slug = _find_slug(registry, selected)
    canary_meta = {
        "is_canary": selected_is_canary,
        "canary_weight_percent": effective_weight,
        "roll": roll,
        "selected": slug or selected.get("handle", "unknown"),
        "total_candidates": len(candidates),
        "canary_candidates": len(canary_agents),
        "stable_candidates": len(stable_agents),
    }

    return {
        "handle": selected.get("handle", ""),
        "slug": slug or "",
        "repo": selected.get("repo", ""),
        "config_source": selected.get("config_source", ""),
        "config_sha": selected.get("config_sha", ""),
        "canary": canary_meta,
    }


def _find_slug(registry: dict[str, Any], agent: dict[str, Any]) -> str | None:
    """Find the slug for an agent in the registry."""
    agents = registry.get("agents", {})
    for slug, entry in agents.items():
        if entry is agent:
            return slug
    return None


def route_by_handle_with_canary(
    registry: dict[str, Any],
    handle: str,
    canary_weight: int | None = None,
    seed: int | None = None,
) -> dict[str, Any] | None:
    """Route a single @handle, applying canary selection if needed.

    For single-handle routing, canary selection only applies when the
    matched agent IS a canary. Otherwise the agent is selected directly.

    Returns:
        dict with routing decision and canary metadata, or None
    """
    agents = registry.get("agents", {})
    matched = None
    for slug, agent in agents.items():
        if agent.get("handle", "") == f"@{handle}":
            matched = (slug, agent)
            break

    if matched is None:
        return None

    slug, agent = matched

    # If the matched agent is a canary, we can still select it directly
    # (single-handle routing doesn't need canary selection — it's already
    # a specific agent). The canary metadata just records the state.
    return {
        "handle": agent.get("handle", ""),
        "slug": slug,
        "repo": agent.get("repo", ""),
        "config_source": agent.get("config_source", ""),
        "config_sha": agent.get("config_sha", ""),
        "canary": {
            "is_canary": is_canary(agent),
            "canary_weight_percent": get_canary_weight(agent),
            "roll": None,
            "selected": slug,
            "total_candidates": 1,
            "canary_candidates": 1 if is_canary(agent) else 0,
            "stable_candidates": 0 if is_canary(agent) else 1,
        },
    }


def route_by_capability_with_canary(
    registry: dict[str, Any],
    capability: str,
    canary_weight: int | None = None,
    seed: int | None = None,
) -> dict[str, Any] | None:
    """Route a capability name, applying canary selection among matching agents.

    If multiple agents have the same capability, canary selection picks
    one. If only one agent matches, it's selected directly.

    Returns:
        dict with routing decision and canary metadata, or None
    """
    agents = registry.get("agents", {})
    candidates = []
    for slug, agent in agents.items():
        caps = agent.get("capabilities", [])
        if isinstance(caps, list) and capability in caps:
            candidates.append(agent)

    if not candidates:
        return None

    if len(candidates) == 1:
        slug = _find_slug(registry, candidates[0])
        return {
            "handle": candidates[0].get("handle", ""),
            "slug": slug or "",
            "repo": candidates[0].get("repo", ""),
            "config_source": candidates[0].get("config_source", ""),
            "config_sha": candidates[0].get("config_sha", ""),
            "canary": {
                "is_canary": is_canary(candidates[0]),
                "canary_weight_percent": get_canary_weight(candidates[0]),
                "roll": None,
                "selected": slug or "",
                "total_candidates": 1,
                "canary_candidates": 1 if is_canary(candidates[0]) else 0,
                "stable_candidates": 0 if is_canary(candidates[0]) else 1,
            },
        }

    # Multiple candidates — apply canary selection
    return select_canary_agent(
        registry,
        candidates,
        canary_weight=canary_weight,
        seed=seed,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(
        description="Canary routing for agent dispatch (RFC #31 Phase 6)"
    )
    parser.add_argument(
        "--lockfile",
        default=None,
        help="Path to agents.lock.toml (default: config/agents.lock.toml)",
    )
    parser.add_argument(
        "--handle",
        default=None,
        help="A specific @handle to look up",
    )
    parser.add_argument(
        "--capability",
        default=None,
        help="A capability name to look up",
    )
    parser.add_argument(
        "--canary-weight",
        type=int,
        default=None,
        help="Override canary weight percentage (default: per-agent or 10%%)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for deterministic testing",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Log the routing decision but exit 0 with dry_run flag",
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

    # Validate arguments
    if not args.handle and not args.capability:
        print("ERROR: --handle or --capability is required", file=sys.stderr)
        raise SystemExit(1)

    # Route
    result: dict[str, Any] | None = None

    if args.handle:
        handle = args.handle.lstrip("@")
        result = route_by_handle_with_canary(
            registry,
            handle,
            canary_weight=args.canary_weight,
            seed=args.seed,
        )
        if result is None:
            print(
                f"ERROR: unknown handle @{handle}", file=sys.stderr
            )
            raise SystemExit(1)
    elif args.capability:
        result = route_by_capability_with_canary(
            registry,
            args.capability,
            canary_weight=args.canary_weight,
            seed=args.seed,
        )
        if result is None:
            print(
                f"ERROR: no agent has capability '{args.capability}'",
                file=sys.stderr,
            )
            raise SystemExit(1)

    if result is None:
        print("ERROR: no routing decision", file=sys.stderr)
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
