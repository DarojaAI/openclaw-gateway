#!/usr/bin/env python3
# scripts/generate-agents-lock.py
#
# Phase-1 lockfile emitter for `agents.lock.toml`.
#
# Reads a validated `.openclaw/agent-config.yaml` and emits (to stdout)
# the TOML fragment that should be merged into the `[agents.<slug>]`
# section of `agents.lock.toml`. This is the *generator*, not the
# orchestrator: it does NOT read or write the lockfile directly. The
# deploy action (Phase-1 sibling workstream) is responsible for
# assembling the final `agents.lock.toml`.
#
# TOML output is produced without external dependencies so this script
# can run in minimal test images. We emit only string, integer, and
# boolean scalars; the only nested structure is the [agents.<slug>]
# table itself.
#
# Refs:
#   DarojaAI/openclaw-gateway#31
#
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

HANDLE_PATTERN = re.compile(r"^@([a-z0-9]([a-z0-9._-]*[a-z0-9])?)$")


def _read_document(path: Path) -> Any:
    """Read a YAML or JSON document. Mirrors validate-agent-config.py."""
    if not path.exists() or not path.is_file():
        print(f"ERROR: document not found: {path}", file=sys.stderr)
        raise SystemExit(2)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {path}: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc

    # JSON path first: tolerant of leading whitespace and tabs. PyYAML
    # rejects tabs in YAML-mode indentation, so JSON-looking bodies
    # (the format we use in BATS) must hit the JSON parser.
    stripped = text.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            print(f"ERROR: JSON parse error in {path}: {exc}", file=sys.stderr)
            raise SystemExit(2) from exc

    # YAML path: prefer PyYAML when available.
    try:
        import yaml  # type: ignore[import-not-found]
    except ImportError:
        yaml = None  # type: ignore[assignment]
    if yaml is not None:
        try:
            return yaml.safe_load(text)
        except yaml.YAMLError as exc:
            print(f"ERROR: YAML parse error in {path}: {exc}", file=sys.stderr)
            raise SystemExit(2) from exc

    # JSON fallback (when PyYAML is unavailable and the body is JSON).
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        print(
            f"ERROR: cannot parse {path} without PyYAML (install PyYAML "
            f"or provide JSON): {exc}",
            file=sys.stderr,
        )
        raise SystemExit(2) from exc


def _toml_escape(value: str) -> str:
    """Escape a string for inclusion in a TOML basic string literal."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _format_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return _toml_escape(value)
    raise ValueError(f"unsupported value type for TOML emission: {type(value).__name__}")


def _resolve_slug(slug_arg: str | None, handle: str) -> str:
    """Derive the slug from --slug or from the handle (after stripping @)."""
    if slug_arg:
        return slug_arg
    match = HANDLE_PATTERN.match(handle)
    if not match:
        print(
            f"ERROR: handle {handle!r} does not match the expected pattern; "
            f"pass --slug explicitly",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return match.group(1)


def _derive_repo(config_source: str | None, repo_arg: str | None) -> str:
    if repo_arg:
        return repo_arg
    if not config_source:
        print(
            "ERROR: --repo not given and config_source missing from config; "
            "pass --repo explicitly",
            file=sys.stderr,
        )
        raise SystemExit(2)
    # config_source looks like:
    # https://github.com/DarojaAI/<repo>/blob/main/.openclaw/agent-config.yaml
    match = re.match(r"^https?://github\.com/([^/]+/[^/]+)/blob/", config_source)
    if not match:
        print(
            f"ERROR: cannot derive repo from config_source {config_source!r}; "
            f"pass --repo explicitly",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    parser.add_argument("--config", required=True, help="Path to agent-config.yaml")
    parser.add_argument("--repo", help="GitHub owner/repo hosting the config (default: derived from config_source)")
    parser.add_argument("--slug", help="Agent slug for [agents.<slug>] (default: derived from handle)")
    parser.add_argument("--config-sha", required=True, help="40-hex git blob SHA of the config file")
    parser.add_argument(
        "--config-source",
        help="Canonical URL to the config in the consumer repo (default: derived from --repo)",
    )
    parser.add_argument(
        "--last-deploy-at",
        help="ISO 8601 timestamp (default: omitted from output)",
    )
    args = parser.parse_args()

    if not re.fullmatch(r"[a-f0-9]{40}", args.config_sha):
        print(f"ERROR: --config-sha must be 40 hex chars: {args.config_sha!r}", file=sys.stderr)
        return 2

    config_path = Path(args.config).expanduser().resolve()
    doc = _read_document(config_path)
    if not isinstance(doc, dict):
        print("ERROR: agent-config must be a mapping", file=sys.stderr)
        return 2

    handle = doc.get("handle")
    contract_version = doc.get("contract_version")
    if not isinstance(handle, str) or not isinstance(contract_version, str):
        print("ERROR: agent-config missing handle or contract_version", file=sys.stderr)
        return 2

    slug = _resolve_slug(args.slug, handle)
    config_source = args.config_source
    repo = _derive_repo(config_source, args.repo)
    if not config_source:
        config_source = f"https://github.com/{repo}/blob/main/.openclaw/agent-config.yaml"

    lines: list[str] = []
    lines.append("[agents.{slug}]".format(slug=slug))
    lines.append(f"repo             = {_format_value(repo)}")
    lines.append(f"handle           = {_format_value(handle)}")
    lines.append(f"contract_version = {_format_value(contract_version)}")
    lines.append(f"config_source    = {_format_value(config_source)}")
    lines.append(f"config_sha       = {_format_value(args.config_sha)}")
    if args.last_deploy_at:
        lines.append(f"last_deploy_at   = {_format_value(args.last_deploy_at)}")

    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
