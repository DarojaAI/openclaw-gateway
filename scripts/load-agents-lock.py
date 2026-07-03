#!/usr/bin/env python3
"""
Read agents.lock.toml from config/ and emit the registry as JSON to stdout.

Usage:
    python3 scripts/load-agents-lock.py [path/to/agents.lock.toml]

Exit codes:
    0  — success (JSON on stdout; empty object if file missing)
    2  — parse error (stderr message, empty JSON on stdout)
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Minimal TOML parser — handles the subset used by agents.lock.toml:
#   - schema_version = "1"
#   - [agents.<slug>]
#     key = "string" | 42 | true | false
#
# No external dependencies.
# ---------------------------------------------------------------------------

# Regex for key = value lines
KV_RE = re.compile(r'^([A-Za-z0-9_\-]+)\s*=\s*(.+)$')
# Regex for section headers like [agents.slug]
SECTION_RE = re.compile(r'^\[([A-Za-z0-9_\-\.]+)\]$')
# Regex for string values
STRING_RE = re.compile(r'^"(.*)"$')
# Regex for integer values
INT_RE = re.compile(r'^-?\d+$')


def _parse_toml_value(raw: str) -> Any:
    """Parse a single TOML scalar value (string, int, bool)."""
    raw = raw.strip()
    # Bool
    if raw == "true":
        return True
    if raw == "false":
        return False
    # String (basic or literal)
    m = STRING_RE.match(raw)
    if m:
        return m.group(1)
    # Integer
    if INT_RE.match(raw):
        return int(raw)
    raise ValueError(f"unrecognised TOML value: {raw!r}")


def _parse_toml(text: str) -> dict[str, Any]:
    """
    Parse a minimal TOML document into a dict.
    Only handles top-level keys and [section.key] tables with scalar values.
    """
    result: dict[str, Any] = {}
    current: dict[str, Any] | None = None
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # Section header
        m = SECTION_RE.match(stripped)
        if m:
            parts = m.group(1).split(".")
            obj = result
            for part in parts:
                obj = obj.setdefault(part, {})
            current = obj
            continue
        # Key = value
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
    """
    Load and parse agents.lock.toml. Returns empty dict if file is missing.
    Raises SystemExit(2) on parse error.
    """
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


def main() -> int:
    default_path = Path("config/agents.lock.toml")
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else default_path
    path = path.expanduser().resolve()

    registry = load_agents_lock(path)

    # Normalise: if file was missing registry is {}; if present but no
    # [agents.*] section, registry is the parsed dict (which should have
    # schema_version + agents).  Output is always valid JSON.
    print(json.dumps(registry, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
