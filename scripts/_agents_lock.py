#!/usr/bin/env python3
"""
Shared agents.lock.toml parser and loader.

Used by route-by-handle.py and capability-dispatch.py to avoid
duplicating TOML parsing and lockfile loading logic.

This module supports the TOML subset used in agents.lock.toml:
- Key-value pairs (strings, integers, booleans)
- Array values (TOML inline arrays like ["a", "b", "c"])
- Section headers ([section] or [section.subsection])
- Comments (lines starting with #)

Refs: DarojaAI/openclaw-gateway#46 (RFC #31 Phase 5)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Minimal TOML parser — same subset as load-agents-lock.py.
# Supports: strings, integers, booleans, inline arrays of strings.
# ---------------------------------------------------------------------------

KV_RE = re.compile(r'^([A-Za-z0-9_\-]+)\s*=\s*(.+)$')
SECTION_RE = re.compile(r'^\[([A-Za-z0-9_\-\.]+)\]$')
STRING_RE = re.compile(r'^"(.*)"$')
INT_RE = re.compile(r'^-?\d+$')
# Inline array of strings: ["a", "b", "c"]
ARRAY_RE = re.compile(r'^\[(.+)\]$')


def _parse_toml_value(raw: str) -> Any:
    raw = raw.strip()
    if raw == "true":
        return True
    if raw == "false":
        return False
    # Check for array of strings
    m = ARRAY_RE.match(raw)
    if m:
        inner = m.group(1).strip()
        if not inner:
            return []
        # Split on commas, parse each element as a string
        items: list[str] = []
        for item in re.split(r',\s*', inner):
            item = item.strip()
            sm = STRING_RE.match(item)
            if sm:
                items.append(sm.group(1))
            else:
                raise ValueError(f"unrecognised TOML array element: {item!r}")
        return items
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
