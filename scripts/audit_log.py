#!/usr/bin/env python3
"""
Audit log for inter-agent bridge calls (RFC #31 Phase 5, Issue #51).

Every bridge call is logged as a JSON line to the audit log file.
The log is queryable via the CLI wrapper `openclaw-gateway-audit.sh`.

Usage:
    python3 scripts/audit_log.py --write \
        --from-agent linux-desktop-seed \
        --to-agent darojaai_architect \
        --contract-version v1 \
        --capability architect-review \
        --channel-id 1501612164098687087

    python3 scripts/audit_log.py --query --from linux-desktop-seed --to darojaai_architect

Audit log path:
    Default: ~/.local/log/openclaw-audit.log
    Override: set OPENCLAW_AUDIT_LOG env var

Exit codes:
    0  — success
    1  — invalid arguments or write failure
    2  — lockfile missing or parse error
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Import shared TOML parser from _agents_lock.py
# ---------------------------------------------------------------------------
from _agents_lock import load_agents_lock

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_LOG_PATH = Path.home() / ".local" / "log" / "openclaw-audit.log"

AUDIT_FIELDS = [
    "ts",
    "from_agent",
    "to_agent",
    "from_handle",
    "to_handle",
    "contract_version",
    "capability",
    "channel_id",
]

EXIT_WRITE_FAILURE = 1
EXIT_LOCKFILE_MISSING = 2


# ---------------------------------------------------------------------------
# Log path
# ---------------------------------------------------------------------------

def get_log_path() -> Path:
    """Return the audit log path, preferring OPENCLAW_AUDIT_LOG env var."""
    env = os.environ.get("OPENCLAW_AUDIT_LOG")
    if env:
        return Path(env)
    return DEFAULT_LOG_PATH


# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

def write_audit_entry(
    from_agent: str,
    to_agent: str,
    from_handle: str,
    to_agent_handle: str,
    contract_version: str,
    capability: str,
    channel_id: str = "",
    log_path: Path | None = None,
) -> None:
    """Append one JSON line to the audit log.

    Creates the log file with mode 0600 if it does not exist.
    """
    path = log_path or get_log_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.touch(mode=0o600, exist_ok=True)

    entry = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "from_agent": from_agent,
        "to_agent": to_agent,
        "from_handle": from_handle,
        "to_handle": to_agent_handle,
        "contract_version": contract_version,
        "capability": capability,
        "channel_id": channel_id,
    }

    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, separators=(",", ":")) + "\n")
    except OSError as exc:
        print(f"ERROR: cannot write audit log: {exc}", file=sys.stderr)
        raise SystemExit(EXIT_WRITE_FAILURE) from exc


# ---------------------------------------------------------------------------
# Query
# ---------------------------------------------------------------------------

def query_audit_log(
    from_agent: str | None = None,
    to_agent: str | None = None,
    capability: str | None = None,
    log_path: Path | None = None,
) -> list[dict[str, Any]]:
    """Read and filter audit log entries.

    Returns matching entries as a list of dicts.
    """
    path = log_path or get_log_path()
    if not path.exists():
        return []

    results: list[dict[str, Any]] = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue  # skip malformed lines
                if from_agent and entry.get("from_agent") != from_agent:
                    continue
                if to_agent and entry.get("to_agent") != to_agent:
                    continue
                if capability and entry.get("capability") != capability:
                    continue
                results.append(entry)
    except OSError as exc:
        print(f"ERROR: cannot read audit log: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    return results


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(
        description="Audit log for inter-agent bridge calls (RFC #31 Phase 5, Issue #51)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # --write subcommand
    write_parser = sub.add_parser("write", help="Append an audit entry")
    write_parser.add_argument("--from-agent", required=True, help="Source agent slug")
    write_parser.add_argument("--to-agent", required=True, help="Target agent slug")
    write_parser.add_argument("--from-handle", required=True, help="Source agent handle")
    write_parser.add_argument("--to-handle", required=True, help="Target agent handle")
    write_parser.add_argument("--contract-version", required=True, help="Contract version")
    write_parser.add_argument("--capability", required=True, help="Capability name")
    write_parser.add_argument("--channel-id", default="", help="Channel ID (snowflake)")
    write_parser.add_argument("--lockfile", default=None, help="Path to agents.lock.toml")
    write_parser.add_argument("--log-path", default=None, help="Path to audit log file")

    # --query subcommand
    query_parser = sub.add_parser("query", help="Query audit log entries")
    query_parser.add_argument("--from", dest="from_agent", default=None, help="Filter by from_agent slug")
    query_parser.add_argument("--to", dest="to_agent", default=None, help="Filter by to_agent slug")
    query_parser.add_argument("--capability", default=None, help="Filter by capability")
    query_parser.add_argument("--log-path", default=None, help="Path to audit log file")

    args = parser.parse_args()

    log_path = Path(args.log_path) if args.log_path else None

    if args.command == "write":
        write_audit_entry(
            from_agent=args.from_agent,
            to_agent=args.to_agent,
            from_handle=args.from_handle,
            to_agent_handle=args.to_handle,
            contract_version=args.contract_version,
            capability=args.capability,
            channel_id=args.channel_id,
            log_path=log_path,
        )
        return 0

    elif args.command == "query":
        results = query_audit_log(
            from_agent=args.from_agent,
            to_agent=args.to_agent,
            capability=args.capability,
            log_path=log_path,
        )
        if not results:
            print("No audit entries found.")
            return 0
        for entry in results:
            print(json.dumps(entry, separators=(",", ":")))
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
