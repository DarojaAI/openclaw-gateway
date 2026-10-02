#!/usr/bin/env python3
"""Pre-flight gate (P0) — per-invocation operator-attribution check.

Part of epic `DarojaAI/linux-desktop-seed#1857` (owner:
`linux_desktop_seed`). Work item: `DarojaAI/openclaw-gateway#119`.

What this is
------------
A deterministic, observable, pre-LLM-call gate. Before any LLM call
lands, the runtime hook layer invokes this script; the script resolves
the invocation's ``actor`` against a known-principals registry and
either allows or rejects. Missing/unknown attribution fails CLOSED
(reject). Every decision emits a structured telemetry event so
downstream lanes can subscribe (audit, cost attribution, handoff
thresholds).

Scope (P0)
----------
- Operator-attribution: actor must resolve to a known principal.
- Structured telemetry: one ``preflight.decision.v1`` JSON line per
  invocation (stdout + optional event log file).
- Deterministic allow/reject surface + exit codes the hook can act on.

NOT in P0 (later phases of epic #1857): tenant-model validation (P1),
capability-consent (P2), routing-posture (P3). The decision surface is
shaped so those phases add checks without changing the wire format.

Wire surface v1 (see docs/contracts/preflight-v1.md)
----------------------------------------------------
- Invocation: CLI args ``evaluate --actor <x> --agent <y>
  [--capability <z>] [--principals <file>] [--event-log <file>]``.
- Decision: JSON on stdout + exit code:
    0  ALLOW   (actor known, agent present)
    1  REJECT  (actor missing/unknown, agent missing — fail-closed)
    2  CONFIG/USAGE error (also fail-closed: hook treats !=0 as block)
- Event: one JSON object per invocation:

    {"event": "preflight.decision.v1", "timestamp": <ISO>,
     "agentId": ..., "actor": ..., "capability": ...,
     "decision": "allow"|"reject", "reason": ..., "principalKnown": bool}

- Principals registry: JSON file (default
  ``config/preflight-principals.json`` in the repo checkout; override
  with ``--principals`` or ``PREFLIGHT_PRINCIPALS_FILE`` so deploy can
  inject environment-specific IDs without hardcoding them in config).

Subcommands
-----------
- ``evaluate`` — run the gate for one invocation (the hook entry point).
- ``--check`` — print gate state (registry path, principal count) and
  exit 0; exits non-zero if the registry is missing/invalid.

Environment
-----------
- ``PREFLIGHT_PRINCIPALS_FILE``  (optional) override principals registry path
- ``PREFLIGHT_EVENT_LOG``        (optional) append decision events to this file

Exit codes
----------
0 allow, 1 reject (fail-closed), 2 usage/config error (fail-closed).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Default principals registry relative to the repo checkout
# (the script lives in scripts/, the registry in config/).
DEFAULT_PRINCIPALS = (
    Path(__file__).resolve().parent.parent / "config" / "preflight-principals.json"
)

EVENT_NAME = "preflight.decision.v1"


# ── Pure decision logic (unit-testable without the CLI) ────────────────────


def evaluate(
    actor: str | None,
    agent_id: str | None,
    capability: str | None,
    principals: list[dict[str, Any]],
) -> dict[str, Any]:
    """Return the decision for one invocation.

    Fail-closed: missing actor, unknown actor, or missing agent all
    REJECT with a machine-readable reason. ``principals`` is a list of
    registry records; a record matches when its ``id`` or ``handle``
    equals the actor string.
    """
    now = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

    if not actor or not str(actor).strip():
        return _decision(now, actor, agent_id, capability, "reject", "actor-missing", False)
    if not agent_id or not str(agent_id).strip():
        return _decision(now, actor, agent_id, capability, "reject", "agent-missing", False)

    known = _principal_matches(actor, principals)
    if not known:
        return _decision(now, actor, agent_id, capability, "reject", "actor-unknown", False)
    return _decision(now, actor, agent_id, capability, "allow", "actor-known", True)


def load_principals(path: str | os.PathLike | None) -> list[dict[str, Any]]:
    """Load and validate the principals registry.

    Raises ValueError on a missing/invalid registry (fail-closed:
    the caller should treat that as exit 2, not as allow-everything).
    """
    registry_path = Path(path or os.environ.get("PREFLIGHT_PRINCIPALS_FILE") or DEFAULT_PRINCIPALS)
    with open(registry_path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get("principals"), list):
        raise ValueError(f"invalid principals registry {registry_path}: expected {{'principals': [...]}}")
    return data["principals"]


def _principal_matches(actor: str, principals: list[dict[str, Any]]) -> bool:
    for p in principals:
        if not isinstance(p, dict):
            continue
        if p.get("id") == actor or p.get("handle") == actor:
            return True
    return False


def _decision(
    now: str,
    actor: str | None,
    agent_id: str | None,
    capability: str | None,
    decision: str,
    reason: str,
    principal_known: bool,
) -> dict[str, Any]:
    return {
        "event": EVENT_NAME,
        "timestamp": now,
        "agentId": agent_id,
        "actor": actor,
        "capability": capability,
        "decision": decision,
        "reason": reason,
        "principalKnown": principal_known,
    }


# ── CLI ──


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="preflight-gate.py",
        description="Per-invocation pre-LLM operator-attribution gate (epic linux-desktop-seed#1857).",
    )
    # Shared options. Defined on a parent parser and added to both the
    # top-level parser (for --check) and the evaluate subparser, so they
    # work before OR after the subcommand (argparse rejects options that
    # live only on the main parser once a subcommand is consumed).
    shared = argparse.ArgumentParser(add_help=False)
    shared.add_argument("--principals", help="Path to principals registry (default: config/preflight-principals.json)")
    shared.add_argument("--event-log", help="Append decision events to this file")

    parser = argparse.ArgumentParser(
        prog="preflight-gate.py",
        parents=[shared],
        description="Per-invocation pre-LLM operator-attribution gate (epic linux-desktop-seed#1857).",
    )
    parser.add_argument("--check", action="store_true", help="Print gate state and exit")
    sub = parser.add_subparsers(dest="command")

    ev = sub.add_parser("evaluate", parents=[shared], help="Evaluate one invocation (hook entry point)")
    ev.add_argument("--actor", help="Invoking principal (id or @handle); empty/missing => reject")
    ev.add_argument("--agent", dest="agent_id", help="Target agent id; empty/missing => reject")
    ev.add_argument("--capability", help="Requested capability (informational in P0)")

    args = parser.parse_args(argv)

    # --check mode: gate state, no evaluation.
    if args.check:
        try:
            principals = load_principals(args.principals)
        except (OSError, ValueError) as e:
            print(f"preflight-gate: CHECK FAILED: {e}", file=sys.stderr)
            return 2
        registry_path = Path(
            args.principals or os.environ.get("PREFLIGHT_PRINCIPALS_FILE") or DEFAULT_PRINCIPALS
        )
        print(f"preflight-gate: registry={registry_path} principals={len(principals)}")
        return 0

    if args.command != "evaluate":
        parser.print_usage(sys.stderr)
        return 2

    try:
        principals = load_principals(args.principals)
    except (OSError, ValueError) as e:
        # Fail-closed: cannot determine attribution => block.
        print(f"preflight-gate: ERROR loading principals: {e}", file=sys.stderr)
        decision = _decision(
            datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            args.actor, args.agent_id, args.capability,
            "reject", "registry-unavailable", False,
        )
        _emit(decision, args.event_log)
        print(json.dumps(decision))
        return 2

    decision = evaluate(args.actor, args.agent_id, args.capability, principals)
    _emit(decision, args.event_log)
    print(json.dumps(decision))
    return 0 if decision["decision"] == "allow" else 1


def _emit(decision: dict[str, Any], event_log: str | None) -> None:
    """Telemetry: append the decision event to the event log if configured."""
    log_path = event_log or os.environ.get("PREFLIGHT_EVENT_LOG")
    if not log_path:
        return
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(decision) + "\n")


if __name__ == "__main__":
    sys.exit(main())