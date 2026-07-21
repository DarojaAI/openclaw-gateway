#!/usr/bin/env python3
"""
Generate openclaw.json bindings from agents.lock.toml.

Reads the lockfile via the shared _agents_lock.py parser, produces a
binding for each (agent, allowed_channel) pair, and merges into the
existing openclaw.json (or a specified output file).

Usage:
    python3 scripts/generate-bindings-from-lockfile.py [OPTIONS]

Options:
    --lockfile PATH          agents.lock.toml path (default: config/agents.lock.toml)
    --openclaw-json PATH     openclaw.json path  (default: config/openclaw.json)
    --output PATH            write merged JSON to PATH (default: overwrite openclaw-json)
    --dry-run                print merged JSON to stdout, do not write
    --verbose                print each binding generated to stderr

Exit codes:
    0  — success
    1  — unexpected error
    2  — parse error (TOML or JSON)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Import shared TOML parser
# ---------------------------------------------------------------------------
# When invoked as a script, scripts/ is not guaranteed to be on sys.path
# (especially when called from tests via absolute path).  Ensure it is.
_SCRIPTS_DIR = str(Path(__file__).resolve().parent)
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from _agents_lock import load_agents_lock  # noqa: E402


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------

def generate_bindings(lockfile_path: Path) -> list[dict]:
    """Return a list of binding dicts derived from the lockfile.

    Each agent with a non-empty ``allowed_channels`` list produces one
    binding per channel.  Agents without ``allowed_channels`` are
    silently skipped.
    """
    registry = load_agents_lock(lockfile_path)
    agents = registry.get("agents", {})

    bindings: list[dict] = []
    for agent_id, agent in agents.items():
        channels = agent.get("allowed_channels", [])
        if not channels:
            continue
        for ch_id in channels:
            bindings.append({
                "agentId": agent_id,
                "match": {
                    "channel": "discord",
                    "peer": {"id": str(ch_id)},
                },
            })
    return bindings


def merge_bindings(
    existing: dict,
    new_bindings: list[dict],
    lockfile_agent_ids: set[str],
) -> dict:
    """Merge *new_bindings* into *existing* openclaw config.

    * Existing bindings whose ``agentId`` is **not** in *lockfile_agent_ids*
      are preserved (they belong to hand-written / legacy config).
    * Existing bindings whose ``agentId`` **is** in *lockfile_agent_ids*
      are replaced by the corresponding entries from *new_bindings*.
    * ``"bindings"`` key is created if absent.
    """
    result = dict(existing)
    bindings: list[dict] = result.get("bindings", [])

    # Keep non-lockfile bindings
    preserved = [
        b for b in bindings
        if b.get("agentId") not in lockfile_agent_ids
    ]

    result["bindings"] = preserved + new_bindings
    return result


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Generate openclaw.json bindings from agents.lock.toml",
    )
    p.add_argument(
        "--lockfile",
        type=Path,
        default=Path("config/agents.lock.toml"),
        help="Path to agents.lock.toml (default: config/agents.lock.toml)",
    )
    p.add_argument(
        "--openclaw-json",
        type=Path,
        default=Path("config/openclaw.json"),
        help="Path to openclaw.json to merge into (default: config/openclaw.json)",
    )
    p.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Write merged JSON here instead of overwriting --openclaw-json",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print merged JSON to stdout; do not write any file",
    )
    p.add_argument(
        "--verbose",
        action="store_true",
        help="Print each generated binding to stderr",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    # --- Load lockfile ---
    try:
        bindings = generate_bindings(args.lockfile)
    except SystemExit as exc:
        # load_agents_lock prints error and calls sys.exit(2)
        return int(exc.code)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if args.verbose:
        for b in bindings:
            print(f"  binding: agentId={b['agentId']} peer={b['match']['peer']['id']}", file=sys.stderr)
        print(f"  total bindings generated: {len(bindings)}", file=sys.stderr)

    # --- Load existing openclaw.json (if it exists) ---
    existing: dict = {}
    if args.openclaw_json.exists():
        try:
            existing = json.loads(args.openclaw_json.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            print(f"ERROR: cannot read {args.openclaw_json}: {exc}", file=sys.stderr)
            return 2

    # --- Compute lockfile agent ids ---
    try:
        registry = load_agents_lock(args.lockfile)
    except SystemExit as exc:
        return int(exc.code)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    lockfile_ids = set(registry.get("agents", {}).keys())

    # --- Merge ---
    merged = merge_bindings(existing, bindings, lockfile_ids)

    # --- Output ---
    out_json = json.dumps(merged, indent=2) + "\n"

    if args.dry_run:
        print(out_json)
        return 0

    dest = args.output or args.openclaw_json
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(out_json, encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot write {dest}: {exc}", file=sys.stderr)
        return 1

    if args.verbose:
        print(f"wrote {len(bindings)} bindings to {dest}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
