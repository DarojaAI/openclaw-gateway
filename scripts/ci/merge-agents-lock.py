#!/usr/bin/env python3
# scripts/ci/merge-agents-lock.py
#
# Phase-2 lockfile merger for `agents.lock.toml`.
#
# Reads all `agents.lock.next.toml` fragment files produced by the
# deploy action and merges them into a single `agents.lock.toml`.
# Each fragment contains a `[agents.<slug>]` section; this script
# combines them under a top-level `schema_version = "1"` header.
#
# Usage:
#   python3 scripts/ci/merge-agents-lock.py \
#       --fragments-dir /tmp/fragments \
#       --output agents.lock.toml
#
# The script is designed to be called from the deploy workflow in
# the gateway repo. It reads one or more TOML fragment files and
# writes the merged output.
#
# Refs:
#   DarojaAI/openclaw-gateway#31
#
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# TOML parser/writer (no external dependencies)
# ---------------------------------------------------------------------------
# We only need to handle the simple subset emitted by
# generate-agents-lock.py: [agents.<slug>] sections with string,
# integer, and boolean values.
# ---------------------------------------------------------------------------


def _parse_toml_value(raw: str) -> Any:
    """Parse a TOML basic-string, integer, or boolean value."""
    raw = raw.strip()
    if raw in ("true", "false"):
        return raw == "true"
    if raw.startswith('"') and raw.endswith('"'):
        return raw[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        pass
    return raw


def _parse_toml_fragment(text: str) -> dict[str, dict[str, Any]]:
    """Parse a TOML fragment file into {section_name: {key: value}}."""
    sections: dict[str, dict[str, Any]] = {}
    current_section: str | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # Section header: [section] or [section.subsection]
        section_match = re.match(r"^\[([^\]]+)\]$", stripped)
        if section_match:
            current_section = section_match.group(1)
            sections.setdefault(current_section, {})
            continue
        # Key = value
        kv_match = re.match(r"^([a-zA-Z0-9_.-]+)\s*=\s*(.+)$", stripped)
        if kv_match and current_section is not None:
            key = kv_match.group(1).strip()
            value = _parse_toml_value(kv_match.group(2))
            sections[current_section][key] = value
            continue
        # Section continuation: bare key = value after a section header
        if current_section is not None:
            kv_match2 = re.match(r"^([a-zA-Z0-9_.-]+)\s*=\s*(.+)$", stripped)
            if kv_match2:
                key = kv_match2.group(1).strip()
                value = _parse_toml_value(kv_match2.group(2))
                sections[current_section][key] = value
    return sections


def _toml_escape_string(value: str) -> str:
    """Escape a string for TOML basic-string output."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _format_value(value: Any) -> str:
    """Format a Python value as a TOML literal."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return _toml_escape_string(value)
    return str(value)


def _write_toml(sections: dict[str, dict[str, Any]], output_path: Path) -> None:
    """Write a TOML file from a parsed sections dict."""
    lines: list[str] = []
    # Write schema_version first if present
    if "schema_version" in sections.get("schema_version", {}):
        lines.append(f"schema_version = {_format_value(sections['schema_version']['schema_version'])}")
        lines.append("")
    elif "schema_version" in sections:
        lines.append(f"schema_version = {_format_value(sections['schema_version'].get('schema_version', '1'))}")
        lines.append("")
    else:
        lines.append('schema_version = "1"')
        lines.append("")

    # Write agent sections in sorted order for determinism
    agent_sections = sorted(
        k for k in sections if k.startswith("agents.")
    )
    # Write other top-level sections first (if any)
    other_sections = sorted(
        k for k in sections if k != "schema_version" and not k.startswith("agents.")
    )
    for section_name in other_sections:
        lines.append(f"[{section_name}]")
        for key, value in sorted(sections[section_name].items()):
            lines.append(f"{key} = {_format_value(value)}")
        lines.append("")

    for section_name in agent_sections:
        lines.append(f"[{section_name}]")
        for key, value in sorted(sections[section_name].items()):
            lines.append(f"{key} = {_format_value(value)}")
        lines.append("")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def merge_fragments(fragments_dir: Path) -> dict[str, dict[str, Any]]:
    """Merge all `agents.lock.next.toml` fragments into one sections dict."""
    merged: dict[str, dict[str, Any]] = {"schema_version": {"schema_version": "1"}}

    fragment_files = sorted(fragments_dir.glob("*.toml"))
    if not fragment_files:
        print(
            f"ERROR: no TOML fragments found in {fragments_dir}",
            file=sys.stderr,
        )
        raise SystemExit(2)

    for fragment_file in fragment_files:
        if fragment_file.name == "agents.lock.toml":
            # Skip the output file if it somehow exists in the fragments dir
            continue
        try:
            text = fragment_file.read_text(encoding="utf-8")
        except OSError as exc:
            print(
                f"ERROR: cannot read {fragment_file}: {exc}",
                file=sys.stderr,
            )
            raise SystemExit(2) from exc
        parsed = _parse_toml_fragment(text)
        for section_name, values in parsed.items():
            if section_name == "schema_version":
                merged["schema_version"].update(values)
                continue
            if not section_name.startswith("agents."):
                merged.setdefault(section_name, {}).update(values)
                continue
            # Check for duplicate slug
            if section_name in merged:
                print(
                    f"ERROR: duplicate section [{section_name}] in "
                    f"fragment {fragment_file.name}",
                    file=sys.stderr,
                )
                raise SystemExit(2)
            merged[section_name] = dict(values)

    return merged


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[1] if __doc__ else "",
    )
    parser.add_argument(
        "--fragments-dir",
        required=True,
        help="Directory containing agents.lock.next.toml fragment files",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path to write the merged agents.lock.toml",
    )
    args = parser.parse_args()

    fragments_dir = Path(args.fragments_dir).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()

    if not fragments_dir.is_dir():
        print(
            f"ERROR: fragments directory not found: {fragments_dir}",
            file=sys.stderr,
        )
        return 2

    merged = merge_fragments(fragments_dir)
    _write_toml(merged, output_path)
    print(f"Merged lockfile written to {output_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
