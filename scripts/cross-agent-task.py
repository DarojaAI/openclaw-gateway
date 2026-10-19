#!/usr/bin/env python3
"""cross-agent-task — durable cross-agent task queue CLI (fleet plan C1).

Manages the durable queue at ``~/.openclaw/cross-agent-tasks/``:

    _pending/<task-id>.json   submitted, unclaimed
    _active/<task-id>.json    claimed (atomic rename from _pending)
    _done/<task-id>.json      completed (atomic rename from _active)

Wire shape + failure modes: docs/contracts/SQLITE-STATE-BOUNDARY.md's
sibling contract CROSS-AGENT-TASK-BUS.md (linux-desktop-seed) — schema v0,
flock-guarded atomic state transitions, no in-place JSON edits.

Commands:
    submit --to AGENT --subject TEXT [--body TEXT] [--from AGENT]
    claim  TASK_ID [--agent AGENT]
    complete TASK_ID [--result TEXT]
    list   [--state pending|active|done|all]

Exit codes: 0 ok; 1 state/usage error (task missing, wrong state, schema);
2 fatal (bus unwritable).
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

TASK_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
ISO_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SCHEMA_VERSION = "v0"
STATES = ("_pending", "_active", "_done")


def bus_root() -> Path:
    root = Path(os.environ.get("TASK_BUS_ROOT", "~/.openclaw/cross-agent-tasks")).expanduser()
    for state in STATES:
        (root / state).mkdir(parents=True, exist_ok=True)
    return root


def agent_identity() -> str:
    return os.environ.get("OPENCLAW_AGENT_ID") or os.environ.get("USER") or "unknown"


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def find_task(root: Path, task_id: str) -> Path | None:
    if not TASK_ID_RE.match(task_id):
        raise ValueError(f"invalid task id: {task_id!r}")
    for state in STATES:
        candidate = root / state / f"{task_id}.json"
        if candidate.is_file():
            return candidate
    return None


class BusLock:
    """Exclusive queue lock for state transitions (contract §5)."""

    def __enter__(self) -> "BusLock":
        self._fh = open(root_lock(self.root), "a+")
        fcntl.flock(self._fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc) -> None:
        fcntl.flock(self._fh, fcntl.LOCK_UN)
        self._fh.close()

    def __init__(self, root: Path) -> None:
        self.root = root


def root_lock(root: Path) -> Path:
    return root / "lock"


def atomic_write(path: Path, data: dict) -> None:
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)  # atomic on one filesystem


def load(path: Path) -> dict:
    with open(path) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("task is not a JSON object")
    return data


def cmd_submit(args: argparse.Namespace) -> int:
    root = bus_root()
    task_id = uuid.uuid4().hex[:12]
    with BusLock(root):
        data = {
            "id": task_id,
            "schema_version": SCHEMA_VERSION,
            "from": args.from_agent or agent_identity(),
            "to": args.to,
            "subject": args.subject,
            "created_at": now_iso(),
        }
        if args.body:
            data["body"] = args.body
        atomic_write(root / "_pending" / f"{task_id}.json", data)
    print(task_id)
    return 0


def cmd_claim(args: argparse.Namespace) -> int:
    root = bus_root()
    with BusLock(root):
        src = find_task(root, args.task_id)
        if src is None or src.parent.name != "_pending":
            print(f"ERROR: task {args.task_id} not found in _pending", file=sys.stderr)
            return 1
        data = load(src)
        data["claimed_by"] = args.agent or agent_identity()
        data["claimed_at"] = now_iso()
        dst = root / "_active" / src.name
        atomic_write(dst, data)  # write-then-rename: content lands atomically
        src.unlink()
    print(args.task_id)
    return 0


def cmd_complete(args: argparse.Namespace) -> int:
    root = bus_root()
    with BusLock(root):
        src = find_task(root, args.task_id)
        if src is None or src.parent.name != "_active":
            print(f"ERROR: task {args.task_id} not found in _active", file=sys.stderr)
            return 1
        data = load(src)
        data["completed_at"] = now_iso()
        if args.result:
            data["result"] = args.result
        dst = root / "_done" / src.name
        atomic_write(dst, data)
        src.unlink()
    print(args.task_id)
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    root = bus_root()
    states = STATES if args.state in (None, "all") else (f"_{args.state}",)
    for state in states:
        state_dir = root / state
        if not state_dir.is_dir():
            continue
        for path in sorted(state_dir.glob("*.json")):
            data = load(path)
            data["_state"] = state[1:]
            print(json.dumps(data, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="cross-agent-task", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_submit = sub.add_parser("submit", help="create a task in _pending/")
    p_submit.add_argument("--to", required=True, help="target agent id or *")
    p_submit.add_argument("--subject", required=True)
    p_submit.add_argument("--body", default=None)
    p_submit.add_argument("--from", dest="from_agent", default=None)
    p_submit.set_defaults(fn=cmd_submit)

    p_claim = sub.add_parser("claim", help="move a task from _pending/ to _active/")
    p_claim.add_argument("task_id")
    p_claim.add_argument("--agent", default=None, help="claiming agent id")
    p_claim.set_defaults(fn=cmd_claim)

    p_done = sub.add_parser("complete", help="move a task from _active/ to _done/")
    p_done.add_argument("task_id")
    p_done.add_argument("--result", default=None)
    p_done.set_defaults(fn=cmd_complete)

    p_list = sub.add_parser("list", help="list tasks (JSON lines)")
    p_list.add_argument("--state", choices=("pending", "active", "done", "all"), default="all")
    p_list.set_defaults(fn=cmd_list)

    args = parser.parse_args(argv)
    try:
        return args.fn(args)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as exc:
        print(f"ERROR: task file is not valid JSON: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
