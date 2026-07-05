#!/usr/bin/env python3
"""
Route a Discord @handle mention to the matching agent in agents.lock.toml.

Usage:
    echo '@linux-desktop-seed hello' | python3 scripts/route-by-handle.py
    python3 scripts/route-by-handle.py --message '@linux-desktop-seed hello'
    python3 scripts/route-by-handle.py --handle @linux-desktop-seed

The script reads agents.lock.toml from config/ (or a custom path) and
looks up the first @handle found in the input text.

Exit codes:
    0  — known handle, JSON on stdout with routing decision
    1  — unknown handle or no handle found (stderr message)
    2  — TOML parse error or lockfile missing

Output (JSON on stdout):
    {
      "handle": "@linux-desktop-seed",
      "slug": "linux-desktop-seed",
      "repo": "DarojaAI/linux-desktop-seed",
      "config_source": "https://...",
      "config_sha": "..."
    }
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Minimal TOML parser — same subset as load-agents-lock.py.
# ---------------------------------------------------------------------------

KV_RE = re.compile(r'^([A-Za-z0-9_\-]+)\s*=\s*(.+)$')
SECTION_RE = re.compile(r'^\[([A-Za-z0-9_\-\.]+)\]$')
STRING_RE = re.compile(r'^"(.*)"$')
INT_RE = re.compile(r'^-?\d+$')


def _parse_toml_value(raw: str) -> Any:
    raw = raw.strip()
    if raw == "true":
        return True
    if raw == "false":
        return False
    m = STRING_RE.match(raw)
    if m:
        return m.group(1)
    if INT_RE.match(raw):
        return int(raw)
    raise ValueError(f"unrecognised TOML value: {raw!r}")


def _parse_toml(text: str) -> dict[str, Any]:
    result: dict[str, Any] = {}
    current: dict[str, Any] | None = None
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = SECTION_RE.match(stripped)
        if m:
            parts = m.group(1).split(".")
            obj = result
            for part in parts:
                obj = obj.setdefault(part, {})
            current = obj
            continue
        m = KV_RE.match(stripped)
        if m:
            key = m.group(1)
            raw_val = m.group(2)
            val = _parse_toml_value(raw_val)
            if current is None:
                result[key] = val
            else:
                current[key] = val
            continue
        raise ValueError(f"line {lineno}: unrecognised syntax: {stripped!r}")
    return result


def load_agents_lock(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {path}: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
    try:
        return _parse_toml(text)
    except ValueError as exc:
        print(f"ERROR: TOML parse error in {path}: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


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
            return {
                "handle": agent_handle,
                "slug": slug,
                "repo": agent.get("repo", ""),
                "config_source": agent.get("config_source", ""),
                "config_sha": agent.get("config_sha", ""),
            }
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
    result = route_by_handle(registry, first_handle)

    if result is None:
        print(
            f"ERROR: unknown handle @{first_handle}", file=sys.stderr
        )
        raise SystemExit(1)

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
