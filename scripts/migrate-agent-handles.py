#!/usr/bin/env python3
"""scripts/migrate-agent-handles.py

Phase-3 migration tool for adding handle fields to agent configs.

Reads agent configs from a directory, checks for valid handle fields,
and outputs a migration report. Handles are in the format @<agent-name>.

Exit codes:
  0 - all agents have valid handles
  1 - some agents need migration (report printed)
  2 - probe failure (directory not found, YAML parse error)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HANDLE_PATTERN = re.compile(r"^@[a-z0-9]([a-z0-9._-]*[a-z0-9])?$")


def _parse_yaml_minimal(text: str) -> dict:
    """Minimal YAML parser for agent-config.yaml files."""
    result: dict = {}
    current_key: str | None = None
    current_indent = 0
    for line in text.splitlines():
        stripped = line.rstrip()
        if not stripped or stripped.lstrip().startswith("#"):
            continue
        indent = len(stripped) - len(stripped.lstrip())
        content = stripped.lstrip()

        if content.startswith("- "):
            # list item — skip for now, we only need top-level keys
            continue

        if ":" in content:
            key, _, rest = content.partition(":")
            key = key.strip()
            rest = rest.strip()
            if indent <= current_indent:
                current_key = key
                current_indent = indent
                if rest:
                    result[key] = rest.strip('"').strip("'")
                else:
                    result[key] = None
            else:
                # nested — skip
                pass
    return result


def suggest_handle(agent_name: str) -> str:
    """Suggest a handle from the agent directory name."""
    slug = agent_name.lower().replace("_", "-").replace(" ", "-")
    return f"@{slug}"


def validate_handle(handle: str) -> bool:
    """Check if a handle matches the required format."""
    return bool(HANDLE_PATTERN.match(handle))


def scan_agents(directory: Path) -> dict:
    """Scan all agent config files in a directory.

    Returns a dict with keys:
      - configured: list of (agent_name, handle) tuples
      - needs_migration: list of (agent_name, suggested_handle) tuples
      - invalid: list of (agent_name, handle, error) tuples
    """
    configured = []
    needs_migration = []
    invalid = []

    if not directory.is_dir():
        return {"configured": configured, "needs_migration": needs_migration, "invalid": invalid}

    for agent_dir in sorted(directory.iterdir()):
        if not agent_dir.is_dir():
            continue

        config_path = agent_dir / "agent-config.yaml"
        if not config_path.exists():
            # No config file — suggest adding one
            suggested = suggest_handle(agent_dir.name)
            needs_migration.append((agent_dir.name, suggested))
            continue

        try:
            text = config_path.read_text(encoding="utf-8")
            config = _parse_yaml_minimal(text)
        except OSError as exc:
            invalid.append((agent_dir.name, "", f"cannot read config: {exc}"))
            continue

        handle = config.get("handle")
        if not handle or not isinstance(handle, str) or not handle.strip():
            suggested = suggest_handle(agent_dir.name)
            needs_migration.append((agent_dir.name, suggested))
        elif not validate_handle(handle):
            invalid.append((agent_dir.name, handle, "invalid format (must be @<agent-name>)"))
        else:
            configured.append((agent_dir.name, handle))

    return {
        "configured": configured,
        "needs_migration": needs_migration,
        "invalid": invalid,
    }


def print_report(result: dict) -> None:
    """Print a human-readable migration report."""
    print("=" * 60)
    print("  Agent Handle Migration Report")
    print("=" * 60)
    print()

    if result["configured"]:
        print(f"✅ Already configured ({len(result['configured'])}):")
        for name, handle in result["configured"]:
            print(f"   {name} -> {handle}")
        print()

    if result["needs_migration"]:
        print(f"🔄 Needs migration ({len(result['needs_migration'])}):")
        for name, suggested in result["needs_migration"]:
            print(f"   {name} -> suggested: {suggested}")
        print()

    if result["invalid"]:
        print(f"❌ Invalid handles ({len(result['invalid'])}):")
        for name, handle, error in result["invalid"]:
            print(f"   {name}: {handle!r} — {error}")
        print()

    total = len(result["configured"]) + len(result["needs_migration"]) + len(result["invalid"])
    print(f"Total: {total} agent(s) scanned")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "directory",
        help="Path to the directory containing agent subdirectories with agent-config.yaml files",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output JSON instead of human-readable report",
    )
    args = parser.parse_args()

    directory = Path(args.directory).expanduser().resolve()
    if not directory.is_dir():
        print(f"ERROR: directory not found: {directory}", file=sys.stderr)
        return 2

    result = scan_agents(directory)

    if args.json:
        import json
        print(json.dumps(result, indent=2))
    else:
        print_report(result)

    # Return code: 0 if all configured, 1 if any need migration, 2 for errors
    if result["invalid"]:
        return 1
    if result["needs_migration"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
