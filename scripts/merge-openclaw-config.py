#!/usr/bin/env python3
# scripts/merge-openclaw-config.py
#
# Step-3 OpenClaw config merge + schema gate (see docs/architecture.md,
# "Config Pipeline (6 Steps)").
#
# The gateway's internal writer briefly emitted a *legacy top-level*
# `agents.list` key alongside the valid `agents.entries` index on
# 2026-10-08, poisoning live configs: OpenClaw's runtime rejects the
# unknown key at boot with exit 78 (`agents: Unrecognized key: "list"`).
# This script is the deploy-side guard for that class of breakage.
#
# Responsibilities
# ----------------
# - Deep-merge a base OpenClaw config with an env-overrides JSON
#   (override wins; the `agents.entries` index and `bindings` arrays
#   dedupe by element `id` instead of wholesale overwrite).
# - Schema-gate the result: fail validation when `agents` carries any
#   unrecognized legacy key (specifically `agents.list`).
# - Offer an opt-in `--repair` that removes the superseded legacy key,
#   so deploy can heal a poisoned config before the runtime restarts.
#
# Exit codes (repo convention, see lib-parse-memory-status.py):
#   0 = config is valid.
#   1 = config is invalid (a legacy/unrecognized key was found and not
#         repairable, or repair was not requested).
#   2 = probe failure (file missing, unreadable, or structural JSON/parse
#         error before validation could run).
#
# Refs:
#   DarojaAI/openclaw-gateway#133
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# Canonical keys OpenClaw's runtime accepts under the top-level `agents`
# object. `entries` is the agent index; `defaults` carries agent-wide
# defaults. Any other key under `agents` is a legacy/unrecognized key the
# runtime rejects at boot (exit 78). The 2026-10-08 poison was `list`.
AGENTS_RECOGNIZED_KEYS = frozenset({"defaults", "entries"})

# Top-level array keys that merge by element identity instead of
# wholesale override. `agents.entries` dedupes the way the older
# `agents.list` did; `bindings` has always merged this way.
IDENTITY_ARRAY_KEYS = frozenset({"agents.entries", "bindings"})

DEFAULT_CONFIG_PATH = (
    Path(__file__).resolve().parent.parent / "config" / "openclaw-defaults.json"
)


def _load_json(path: Path) -> Any:
    """Read and parse a JSON document, exiting 2 on any probe failure."""
    if not path.is_file():
        print(f"ERROR: config not found: {path}", file=sys.stderr)
        raise SystemExit(2)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: could not parse {path}: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


def _merge_identity_list(base: list[Any], override: list[Any]) -> list[Any]:
    """Merge two arrays by element `id`; override replaces an equal id."""
    by_id: dict[str, Any] = {}
    for item in (*base, *override):
        if isinstance(item, dict) and isinstance(item.get("id"), str):
            by_id[item["id"]] = item
    return list(by_id.values())


def _deep_merge(base: Any, override: Any, path: tuple[str, ...] = ()) -> Any:
    """Deep-merge `override` into `base`, returning a new structure.

    Dicts merge recursively; scalars/arrays override unless the array lives
    at an IDENTITY_ARRAY_KEYS path (where elements dedupe by `id`).
    """
    key_path = ".".join(path)
    if isinstance(base, dict) and isinstance(override, dict):
        out = dict(base)
        for key, value in override.items():
            keypath = path + (key,)
            current = out.get(key)
            if isinstance(current, dict) and isinstance(value, dict):
                out[key] = _deep_merge(current, value, keypath)
            elif isinstance(value, list) and ".".join(keypath) in IDENTITY_ARRAY_KEYS:
                out[key] = _merge_identity_list(
                    current if isinstance(current, list) else [], value
                )
            else:
                out[key] = value
        return out
    if (
        isinstance(base, list)
        and isinstance(override, list)
        and key_path in IDENTITY_ARRAY_KEYS
    ):
        return _merge_identity_list(base, override)
    return override


def _schema_errors(doc: Any) -> list[tuple[str, str]]:
    """Return [(path, detail)] schema violations. Empty list means valid."""
    errors: list[tuple[str, str]] = []
    agents = doc.get("agents") if isinstance(doc, dict) else None
    if agents is None:
        return errors
    if not isinstance(agents, dict):
        errors.append(("agents", "expected an object"))
        return errors
    for key in agents:
        if key not in AGENTS_RECOGNIZED_KEYS:
            errors.append(
                (
                    f"agents.{key}",
                    'unrecognized legacy key rejected by OpenClaw at boot (exit 78)',
                )
            )
    return errors


def _repair(doc: Any) -> list[tuple[str, str]]:
    """Remove superseded legacy keys. Returns [(path, detail)] of actions.

    Data-safety: `agents.list` is only dropped when the canonical
    `agents.entries` index is present to carry the same data. If `list`
    exists alone, repair refuses to destroy it (reported, not removed).
    """
    actions: list[tuple[str, str]] = []
    agents = doc.get("agents") if isinstance(doc, dict) else None
    if not isinstance(agents, dict):
        return actions
    if "list" in agents:
        if isinstance(agents.get("entries"), dict):
            del agents["list"]
            actions.append(("agents.list", "removed legacy key (agents.entries present)"))
        else:
            actions.append(
                (
                    "agents.list",
                    "legacy key present but no agents.entries to supersede it — "
                    "not auto-removed; requires manual migration",
                )
            )
    return actions


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Merge and schema-gate an OpenClaw config (guards legacy agents.list poison)."
    )
    parser.add_argument(
        "config",
        nargs="?",
        default=str(DEFAULT_CONFIG_PATH),
        help=(
            "Path to the OpenClaw config JSON to merge/validate "
            f"(default: {DEFAULT_CONFIG_PATH})"
        ),
    )
    parser.add_argument(
        "--overrides",
        default=None,
        help=(
            "Path to an env-overrides JSON to deep-merge (arrays override "
            "except agents.entries/bindings which dedupe by id)."
        ),
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Write the merged/repaired result here instead of stdout.",
    )
    parser.add_argument(
        "--validate",
        action="store_true",
        help="Validate only (skip merge and writes).",
    )
    parser.add_argument(
        "--repair",
        action="store_true",
        help=(
            "Opt-in: remove superseded legacy agents.* keys (e.g. agents.list) "
            "when a canonical key carries the same data. Default is fail-fast."
        ),
    )
    args = parser.parse_args()

    config_path = Path(args.config)
    doc = _load_json(config_path)

    if not isinstance(doc, dict):
        print("ERROR: config root must be a JSON object", file=sys.stderr)
        return 2

    if not args.validate and args.overrides:
        overrides = _load_json(Path(args.overrides))
        doc = _deep_merge(doc, overrides)

    errors = _schema_errors(doc)
    if errors and not args.repair:
        for path_, detail in errors:
            print(f"INVALID: {path_}: {detail}")
        print(
            "Use --repair to remove superseded legacy keys (opt-in).",
            file=sys.stderr,
        )
        return 1

    if args.repair:
        for path_, detail in _repair(doc):
            print(f"REPAIRED: {path_}: {detail}")
        errors = _schema_errors(doc)
        if errors:
            for path_, detail in errors:
                print(f"INVALID: {path_}: {detail}")
            return 1

    if args.output:
        try:
            Path(args.output).write_text(
                json.dumps(doc, indent=2) + "\n", encoding="utf-8"
            )
        except OSError as exc:
            print(f"ERROR: could not write {args.output}: {exc}", file=sys.stderr)
            return 2
    elif not args.validate:
        print(json.dumps(doc, indent=2))

    return 0


if __name__ == "__main__":
    sys.exit(main())