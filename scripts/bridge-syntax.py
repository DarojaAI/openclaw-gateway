#!/usr/bin/env python3
"""
Parse bridge syntax @A ask @B <question> and emit a JSON routing decision.

Usage:
    python3 scripts/bridge-syntax.py <message> [path/to/agents.lock.toml]

Exit codes:
    0  — success (JSON routing decision on stdout)
    1  — malformed syntax or unknown agent
    2  — lockfile missing or parse error
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
# Bridge syntax
# ---------------------------------------------------------------------------

# Matches: @source ask @target <rest>
BRIDGE_RE = re.compile(
    r'^@([A-Za-z0-9_-]+)\s+ask\s+@([A-Za-z0-9_-]+)\s+(.+)$'
)


def parse_bridge_syntax(message: str) -> tuple[str, str, str]:
    """
    Parse bridge syntax from a message string.

    Returns (source_handle, target_handle, question).

    Raises ValueError on malformed syntax.
    """
    m = BRIDGE_RE.match(message.strip())
    if not m:
        raise ValueError(
            f"malformed bridge syntax: expected @A ask @B <question>, "
            f"got {message!r}"
        )
    source = m.group(1)
    target = m.group(2)
    question = m.group(3).strip()
    return f"@{source}", f"@{target}", question


def resolve_agent(
    handle: str,
    registry: dict[str, Any],
    lockfile_path: Path,
) -> dict[str, Any]:
    """
    Look up an agent handle in the registry.

    Returns the agent entry dict if found. Raises ValueError if unknown.
    """
    agents = registry.get("agents", {})
    # Match on the "handle" field, not the TOML key (which may use
    # underscores while the handle uses hyphens).
    for _slug, agent in agents.items():
        agent_handle = agent.get("handle", "")
        if agent_handle == handle:
            return agent
    raise ValueError(
        f"unknown agent {handle!r} in lockfile {lockfile_path}"
    )


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(
        description="Parse bridge syntax @A ask @B <question> and emit a JSON routing decision",
    )
    parser.add_argument("message", help="Bridge syntax message")
    parser.add_argument(
        "lockfile",
        nargs="?",
        default="config/agents.lock.toml",
        help="Path to agents.lock.toml",
    )
    parser.add_argument("--audit", action="store_true", help="Write audit log entry")
    parser.add_argument("--contract-version", default="v1", help="Contract version")
    parser.add_argument("--capability", default="bridge", help="Capability name")
    parser.add_argument("--channel-id", default="", help="Channel ID (snowflake)")
    parser.add_argument("--log-path", default=None, help="Path to audit log file")
    args = parser.parse_args()

    message = args.message
    lockfile_path = Path(args.lockfile).expanduser().resolve()

    # 1. Parse the syntax
    try:
        source_handle, target_handle, question = parse_bridge_syntax(message)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    # 2. Load lockfile
    registry = load_agents_lock(lockfile_path)
    if not registry:
        print(
            f"ERROR: lockfile not found or empty: {lockfile_path}",
            file=sys.stderr,
        )
        return 2

    # 3. Resolve both agents
    try:
        source_agent = resolve_agent(source_handle, registry, lockfile_path)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    try:
        target_agent = resolve_agent(target_handle, registry, lockfile_path)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    # 4. Emit routing decision
    routing = {
        "source_agent": {
            "handle": source_handle,
            "slug": source_handle.lstrip("@"),
            "repo": source_agent.get("repo", ""),
        },
        "target_agent": {
            "handle": target_handle,
            "slug": target_handle.lstrip("@"),
            "repo": target_agent.get("repo", ""),
        },
        "question": question,
        "bridge_syntax": message.strip(),
    }
    print(json.dumps(routing, indent=2))

    # 5. Write audit log entry if --audit flag is set
    if args.audit:
        from audit_log import write_audit_entry
        write_audit_entry(
            from_agent=source_handle.lstrip("@"),
            to_agent=target_handle.lstrip("@"),
            from_handle=source_handle,
            to_agent_handle=target_handle,
            contract_version=args.contract_version,
            capability=args.capability,
            channel_id=args.channel_id,
            log_path=Path(args.log_path) if args.log_path else None,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
