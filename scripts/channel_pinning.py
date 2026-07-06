#!/usr/bin/env python3
"""
Channel pinning enforcement for agent routing (RFC #31 Phase 5, Issues #47/#48).

Each agent in agents.lock.toml declares an `allowed_channels` list of Discord
channel IDs (snowflakes). When a routing decision resolves an @handle or
@capability to an agent, the originating channel must be in that list.

Two modes per RFC #48:
  - dry_run = True  → log the violation to stderr, still emit the routing
                       decision on stdout, exit 0. Caller checks stderr.
  - dry_run = False → log the violation to stderr, exit 4 with no stdout
                       routing decision. (Enforcement mode; requires
                       enforce_channel_pinning = True at agent level.)

Per-agent flags (from agent-config.yaml / lockfile):
  - enforce_channel_pinning (bool, default False) — must be True to enforce;
                                                   ignored when dry_run is True
  - dry_run                  (bool, default True)  — flip off to enforce

This module is stdlib-only and shared by route-by-handle.py,
capability-dispatch.py, and (eventually) bridge-syntax.py.

Refs:
  DarojaAI/openclaw-gateway#47 (Phase 5 channel pinning enforcement)
  DarojaAI/openclaw-gateway#48 (Phase 5 dry-run mode)
"""

from __future__ import annotations

import sys
from typing import Any


# Exit code reserved for channel pinning enforcement violation.
# 0=ok, 1=unknown handle/capability, 2=lockfile missing/parse, 3=reserved,
# 4=channel pinning violation in enforcement mode.
EXIT_CHANNEL_PINNING_VIOLATION = 4


def get_allowed_channels(agent: dict[str, Any]) -> list[str]:
    """Return the allowed_channels list from a lockfile agent entry.

    Tolerant of missing key (returns empty list). Items may be ints (snowflakes
    that arrived as TOML integers) or strings; we normalize to strings.
    """
    raw = agent.get("allowed_channels", [])
    if not isinstance(raw, list):
        return []
    out: list[str] = []
    for item in raw:
        if isinstance(item, int):
            out.append(str(item))
        elif isinstance(item, str):
            out.append(item)
        # else: skip silently — schema validates this, defensive only
    return out


def is_dry_run(agent: dict[str, Any]) -> bool:
    """Return True if this agent is in dry-run mode.

    Default True per RFC #48: "Dry-run mode is enabled by default for one
    week. After dry-run, enforcement is enabled." So agents without the
    field are dry-run by default.
    """
    val = agent.get("dry_run")
    if val is None:
        return True
    return bool(val)


def is_enforcement_enabled(agent: dict[str, Any]) -> bool:
    """Return True if channel pinning is being enforced for this agent.

    Requires both `enforce_channel_pinning: True` AND `dry_run: False`.
    Default is False (per-agent opt-in to enforcement).
    """
    enforce = agent.get("enforce_channel_pinning", False)
    if not bool(enforce):
        return False
    if is_dry_run(agent):
        return False
    return True


def check_channel_pinning(
    agent: dict[str, Any],
    channel_id: str | int | None,
) -> dict[str, Any]:
    """
    Decide whether a routing decision from `agent` is allowed to fire in
    `channel_id`.

    Returns a dict with these keys:
      - allowed       (bool):  True if routing is permitted (or dry-run),
                              False if it must be blocked.
      - enforced      (bool):  True if enforcement is on for this agent.
                                False when in dry-run mode (even if violated).
      - dry_run       (bool):  True if this agent is in dry-run mode.
      - violation     (bool):  True if channel_id is not in allowed_channels.
      - channel_id    (str|None): normalized to string when present, else None.
      - allowed_channels (list[str]): the agent's allowed channels (for logs).

    The function does NOT print or exit. Callers (route-by-handle.py,
    capability-dispatch.py) handle the actual emit/exit based on this dict.

    If channel_id is None or empty, we treat that as "no channel context"
    and return allowed=True with a violation=False (caller didn't supply
    a channel, so we can't check). This keeps backward compatibility for
    callers that don't pass --channel.
    """
    allowed_channels = get_allowed_channels(agent)
    dry_run = is_dry_run(agent)
    enforced = is_enforcement_enabled(agent)

    # Normalize channel_id
    channel_norm: str | None = None
    if channel_id is not None and channel_id != "":
        channel_norm = str(channel_id)

    # No channel context → cannot check; treat as allowed (back-compat).
    if channel_norm is None:
        return {
            "allowed": True,
            "enforced": enforced,
            "dry_run": dry_run,
            "violation": False,
            "channel_id": None,
            "allowed_channels": allowed_channels,
            "reason": "no channel context provided",
        }

    violation = channel_norm not in allowed_channels

    # In dry-run mode (regardless of enforcement flag), allow + log.
    # In enforcement mode (enforce=True, dry_run=False), block + exit.
    if violation:
        allowed = not enforced
    else:
        allowed = True

    return {
        "allowed": allowed,
        "enforced": enforced,
        "dry_run": dry_run,
        "violation": violation,
        "channel_id": channel_norm,
        "allowed_channels": allowed_channels,
        "reason": (
            "channel not in allowed_channels"
            if violation
            else "channel in allowed_channels"
        ),
    }


def log_violation(
    agent_handle: str,
    decision: dict[str, Any],
) -> None:
    """
    Emit a one-line human-readable violation record to stderr.

    Format: CHANNEL_PINNING_VIOLATION: handle=@<handle> channel=<id>
            allowed=<csv> dry_run=<bool>

    This is the contract for log scrapers: a single line per violation,
    prefix CHANNEL_PINNING_VIOLATION, stable key=value format.
    """
    handle = agent_handle
    channel = decision.get("channel_id", "?")
    allowed = ",".join(decision.get("allowed_channels", []))
    dry_run = decision.get("dry_run", True)
    print(
        f"CHANNEL_PINNING_VIOLATION: handle={handle} "
        f"channel={channel} allowed={allowed} dry_run={dry_run}",
        file=sys.stderr,
    )
