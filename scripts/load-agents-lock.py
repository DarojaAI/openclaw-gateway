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
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Import shared TOML parser from _agents_lock.py
# ---------------------------------------------------------------------------
from _agents_lock import load_agents_lock


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
