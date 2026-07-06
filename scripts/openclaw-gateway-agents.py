#!/usr/bin/env python3
"""
Read agents.lock.toml from config/ and print a human-readable table of agents.

Usage:
    python3 scripts/openclaw-gateway-agents.py [path/to/agents.lock.toml]

Exit codes:
    0  — success (table on stdout)
    2  — parse error (stderr message)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Import shared TOML parser from _agents_lock.py
# ---------------------------------------------------------------------------
from _agents_lock import load_agents_lock


def _trunc(s: str, maxlen: int) -> str:
    """Truncate a string to maxlen, appending '…' if needed."""
    if len(s) <= maxlen:
        return s
    return s[: maxlen - 1] + "…"


def _fmt_field(val: Any, maxlen: int = 24) -> str:
    """Format a value for table display."""
    if val is None:
        return "—"
    s = str(val)
    return _trunc(s, maxlen)


def print_agents_table(registry: dict[str, Any]) -> None:
    agents = registry.get("agents", {})
    if not agents:
        print("No agents found in agents.lock.toml")
        return

    # Column definitions: (header, field_key, width)
    columns = [
        ("Handle", "handle", 28),
        ("Repo", "repo", 36),
        ("Capabilities", "capabilities", 24),
        ("Role", "role", 16),
        ("Heartbeat", "heartbeat_config", 20),
    ]

    # Build rows
    rows: list[list[str]] = []
    for slug, agent in sorted(agents.items()):
        row: list[str] = [slug]
        for header, key, width in columns:
            row.append(_fmt_field(agent.get(key), width))
        rows.append(row)

    # Calculate column widths
    slug_width = max(len("Slug"), max(len(r[0]) for r in rows)) + 2
    col_widths = [slug_width] + [width for _, _, width in columns]

    # Print header
    header = ["Slug"] + [c[0] for c in columns]
    header_line = "".join(
        f"{h:<{w}}" for h, w in zip(header, col_widths)
    )
    separator = "".join(
        "-" * w for w in col_widths
    )
    print(header_line)
    print(separator)

    # Print rows
    for row in rows:
        line = "".join(
            f"{v:<{w}}" for v, w in zip(row, col_widths)
        )
        print(line)

    print(f"\n{len(agents)} agent(s) registered.")


def main() -> int:
    default_path = Path("config/agents.lock.toml")
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else default_path
    path = path.expanduser().resolve()

    registry = load_agents_lock(path)

    if not registry:
        print("No agents.lock.toml found")
        return 0

    print_agents_table(registry)
    return 0


if __name__ == "__main__":
    sys.exit(main())
