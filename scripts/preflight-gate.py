#!/usr/bin/env python3
"""Pre-flight gate (P0+P1+P2+P3) — per-invocation pre-LLM gate.

Part of epic `DarojaAI/linux-desktop-seed#1857` (owner:
`linux_desktop_seed`). Work items: `DarojaAI/openclaw-gateway#119`
(P0), `DarojaAI/openclaw-gateway#121` (P1), `DarojaAI/openclaw-gateway#123` (P2),
`DarojaAI/openclaw-gateway#125` (P3).

What this is
------------
A deterministic, observable, pre-LLM-call gate. Before any LLM call
lands, the runtime hook layer invokes this script; the script checks:

- (P0) operator-attribution: the invocation's ``actor`` resolves to a
  known principal in the registry;
- (P1) tenant-model: when a daroja-tenancy broker is wired
  (``TENANCY_BROKER_URL``), the invocation's tenant context
  (counterparty/client/project triple) is present and consistent with
  the round-2 contract;
- (P2) capability-consent: when a consent registry is wired
  (``PREFLIGHT_CONSENT_FILE``), the requested capability must resolve
  to an explicit ``granted`` record for the agent (L-001 §3);
- (P3) routing-posture (L-001 §6): when a posture registry is wired
  (``PREFLIGHT_POSTURE_FILE``), the invocation's ``--route`` must be
  in the agent's active route set.

Everything fails CLOSED (reject). Every decision emits a structured
``preflight.decision.v1`` telemetry event so downstream lanes can
subscribe (audit, cost attribution, handoff thresholds).

Scope
-----
- P0: operator-attribution + structured telemetry + allow/reject surface.
- P1: tenant-model validation against the round-2 broker surface
  (``POST /auth/verify`` → ``{triple, valid, exp}``; triple =
  ``counterparty_id``/``client_id``/``project_id``). When the broker is
  NOT wired (env unset), the tenant check is skipped and recorded as
  ``tenant: "skipped"`` — environments without tenancy keep working.
- P2: capability-consent (L-001 §3). When a consent registry is wired
  (``PREFLIGHT_CONSENT_FILE`` set), a requested capability with no
  explicit ``granted`` record for the agent REJECTS — silent capability
  introductions are blocked pre-flight. Unwired ⇒ ``consent: "skipped"``
  (P0/P1 behavior unchanged).
- P3: routing-posture (L-001 §6). When a posture registry is wired
  (``PREFLIGHT_POSTURE_FILE`` set or ``--posture-file`` given), a
  request whose ``--route`` is not in the agent's active route set
  REJECTS. Unwired ⇒ ``posture: "skipped"`` (P0/P1/P2 behavior
  unchanged).

The decision surface is shaped so later phases of epic #1857 (P4
downstream rollout) add checks without changing the wire format.

Wire surface v1 (see docs/contracts/preflight-v1.md)
----------------------------------------------------
- Invocation: CLI args ``evaluate --actor <x> --agent <y>
  [--capability <z>] [--route <r>] [--tenant-jwt <jwt>] [--audience <a>]
  [--counterparty-id .. --client-id .. --project-id ..]
  [--consent-file <file>] [--posture-file <file>] [--principals <file>]
  [--event-log <file>]``.
- Decision: JSON on stdout + exit code:
    0  ALLOW   (all wired checks passed / skipped)
    1  REJECT  (any check failed — fail-closed)
    2  CONFIG/USAGE error (also fail-closed: hook treats !=0 as block)
- Event: one JSON object per invocation:

    {"event": "preflight.decision.v1", "timestamp": <ISO>,
     "agentId": ..., "actor": ..., "capability": ...,
     "decision": "allow"|"reject", "reason": ..., "principalKnown": bool,
     "tenant": "ok"|"invalid"|"missing"|"skipped",
     "triple": {counterparty_id, client_id, project_id}?,
     "consent": "ok"|"missing"|"revoked"|"invalid"|"skipped",
     "posture": "ok"|"missing"|"invalid"|"skipped"}

- Principals registry: JSON file (default
  ``config/preflight-principals.json`` in the repo checkout; override
  with ``--principals`` or ``PREFLIGHT_PRINCIPALS_FILE`` so deploy can
  inject environment-specific IDs without hardcoding them in config).
- Consent registry: JSON file (default
  ``config/preflight-consent.json`` in the repo checkout; override with
  ``--consent-file`` or ``PREFLIGHT_CONSENT_FILE``).
- Posture registry: JSON file (default
  ``config/preflight-posture.json`` in the repo checkout; override with
  ``--posture-file`` or ``PREFLIGHT_POSTURE_FILE``).

Subcommands
-----------
- ``evaluate`` — run the gate for one invocation (the hook entry point).
- ``--check`` — print gate state (registry paths, principal count,
  tenant broker wiring, consent + posture registry wiring) and exit 0;
  exits non-zero if a registry is missing/invalid.

Environment
-----------
- ``PREFLIGHT_PRINCIPALS_FILE``  (optional) override principals registry path
- ``PREFLIGHT_CONSENT_FILE``     (optional) override consent registry path;
                                 when set, the consent check is enforced
- ``PREFLIGHT_POSTURE_FILE``     (optional) override posture registry path;
                                 when set, the posture check is enforced
- ``PREFLIGHT_EVENT_LOG``        (optional) append decision events to this file
- ``TENANCY_BROKER_URL``         (optional) daroja-tenancy broker base URL;
                                 when set, the tenant check is enforced

Exit codes
----------
0 allow, 1 reject (fail-closed), 2 usage/config error (fail-closed).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Default registries relative to the repo checkout (the script lives in
# scripts/, the registries in config/).
DEFAULT_PRINCIPALS = (
    Path(__file__).resolve().parent.parent / "config" / "preflight-principals.json"
)
DEFAULT_CONSENT = (
    Path(__file__).resolve().parent.parent / "config" / "preflight-consent.json"
)
DEFAULT_POSTURE = (
    Path(__file__).resolve().parent.parent / "config" / "preflight-posture.json"
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


def tenant_check(
    jwt: str | None,
    audience: str | None,
    counterparty_id: str | None,
    client_id: str | None,
    project_id: str | None,
) -> dict[str, Any]:
    """P1 tenant-model check against the daroja-tenancy round-2 broker.

    Active ONLY when ``TENANCY_BROKER_URL`` is set (deploy wires it via
    env; DAT contract). When unwired, the check is skipped and recorded
    as ``status: "skipped"`` so environments without tenancy keep
    working (P0 behavior unchanged).

    When active:
      - JWT path: ``POST <broker>/auth/verify`` with the JWT (+ optional
        expected audience); the broker returns ``{triple, valid, exp}``.
        ``valid != true`` or a failed/unreachable call => fail-closed
        reject.
      - Direct-triple path (no JWT): all three ids present and non-empty
        satisfies the presence requirement.
      - Neither => ``status: "missing"`` (reject).

    Returns ``{"status": ..., "reason": ..., "triple": {...}?}``.
    """
    broker = os.environ.get("TENANCY_BROKER_URL", "").strip()
    if not broker:
        return {"status": "skipped", "reason": "tenant-broker-unwired"}

    if jwt:
        try:
            payload: dict[str, Any] = {"jwt": jwt}
            if audience:
                payload["expected_audience"] = audience
            req = urllib.request.Request(
                broker.rstrip("/") + "/auth/verify",
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except Exception as e:  # noqa: BLE001 — fail-closed on any transport error
            return {"status": "invalid", "reason": "tenant-broker-unreachable", "detail": str(e)}
        triple = body.get("triple")
        if not body.get("valid") or not isinstance(triple, dict):
            return {"status": "invalid", "reason": "tenant-jwt-invalid", "triple": triple}
        return {"status": "ok", "reason": "tenant-jwt-verified", "triple": triple}

    if counterparty_id and client_id and project_id:
        return {
            "status": "ok",
            "reason": "tenant-triple-present",
            "triple": {
                "counterparty_id": counterparty_id,
                "client_id": client_id,
                "project_id": project_id,
            },
        }
    return {"status": "missing", "reason": "tenant-context-missing"}


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


def load_consent(path: str | os.PathLike | None) -> dict[str, Any]:
    """Load and validate the consent registry.

    Shape: ``{"version": 1, "consent": {"<agent_id>": {"<capability>": "granted"|"revoked"}}}``.

    Raises ValueError on a missing/invalid registry (fail-closed:
    the caller should treat that as exit 2, not as allow-everything).
    """
    registry_path = Path(path or os.environ.get("PREFLIGHT_CONSENT_FILE") or DEFAULT_CONSENT)
    with open(registry_path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get("consent"), dict):
        raise ValueError(f"invalid consent registry {registry_path}: expected {{'consent': {{...}}}}")
    return data["consent"]


def consent_check(
    capability: str | None,
    agent_id: str | None,
    consent_registry: dict[str, Any] | None,
) -> dict[str, Any]:
    """P2 capability-consent check (L-001 §3).

    Active ONLY when a consent registry is wired (``PREFLIGHT_CONSENT_FILE``
    set or ``--consent-file`` given; deploy wires it via env, DAT
    contract). When unwired, the check is skipped and recorded as
    ``status: "skipped"`` so environments without the consent layer keep
    P0/P1 behavior unchanged.

    When active, the requested capability must resolve to an explicit
    ``granted`` record for the agent:
      - no capability requested        => ``missing`` (reject)
      - capability has no record       => ``missing`` (reject)
      - capability record is ``revoked`` => ``revoked`` (reject)
      - capability record is ``granted`` => ``ok`` (allow)

    Returns ``{"status": ..., "reason": ...}``. ``consent_registry`` is
    the loaded registry value (None when unwired); the caller decides
    wiring from env/CLI, mirroring tenant_check's env gating.
    """
    if consent_registry is None:
        return {"status": "skipped", "reason": "consent-registry-unwired"}
    if not capability or not str(capability).strip():
        return {"status": "missing", "reason": "consent-capability-missing"}
    agent_grants = consent_registry.get(agent_id or "")
    if not isinstance(agent_grants, dict):
        return {"status": "missing", "reason": "consent-missing"}
    record = agent_grants.get(capability)
    if record == "granted":
        return {"status": "ok", "reason": "consent-granted"}
    if record == "revoked":
        return {"status": "revoked", "reason": "consent-revoked"}
    return {"status": "missing", "reason": "consent-missing"}


def load_posture(path: str | os.PathLike | None) -> dict[str, Any]:
    """Load and validate the posture registry.

    Shape: ``{"version": 1, "posture": {"<agent_id>": ["<route>", ...]}}`` —
    the active routing-matrix (L-001 §6) route set per agent.

    Raises ValueError on a missing/invalid registry (fail-closed:
    the caller should treat that as exit 2, not as allow-everything).
    """
    registry_path = Path(path or os.environ.get("PREFLIGHT_POSTURE_FILE") or DEFAULT_POSTURE)
    with open(registry_path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get("posture"), dict):
        raise ValueError(f"invalid posture registry {registry_path}: expected {{'posture': {{...}}}}")
    return data["posture"]


def posture_check(
    route: str | None,
    agent_id: str | None,
    posture_registry: dict[str, Any] | None,
) -> dict[str, Any]:
    """P3 routing-posture check (L-001 §6).

    Active ONLY when a posture registry is wired (``PREFLIGHT_POSTURE_FILE``
    set or ``--posture-file`` given; deploy wires it via env, DAT
    contract). When unwired, the check is skipped and recorded as
    ``status: "skipped"`` so environments without the posture layer keep
    P0/P1/P2 behavior unchanged.

    When active, the invocation's ``--route`` must be in the agent's
    active route set:
      - no route requested              => ``missing`` (reject)
      - agent has no route set          => ``missing`` (reject)
      - route not in the active set     => ``invalid`` (reject)
      - route in the active set         => ``ok`` (allow)

    Returns ``{"status": ..., "reason": ...}``. ``posture_registry`` is
    the loaded registry value (None when unwired); the caller decides
    wiring from env/CLI, mirroring tenant_check/consent_check gating.
    """
    if posture_registry is None:
        return {"status": "skipped", "reason": "posture-registry-unwired"}
    if not route or not str(route).strip():
        return {"status": "missing", "reason": "posture-route-missing"}
    active_routes = posture_registry.get(agent_id or "")
    if not isinstance(active_routes, list):
        return {"status": "missing", "reason": "posture-missing"}
    if route in active_routes:
        return {"status": "ok", "reason": "posture-active"}
    return {"status": "invalid", "reason": "posture-mismatch"}


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
    shared.add_argument("--consent-file", help="Path to consent registry (default: config/preflight-consent.json; wiring = env PREFLIGHT_CONSENT_FILE or this flag)")
    shared.add_argument("--posture-file", help="Path to posture registry (default: config/preflight-posture.json; wiring = env PREFLIGHT_POSTURE_FILE or this flag)")
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
    ev.add_argument("--capability", help="Requested capability (enforced by the P2 consent check when wired)")
    ev.add_argument("--route", help="Invocation route (L-001 §6 routing-matrix row; enforced by the P3 posture check when wired)")
    # P1 tenant-model context.
    ev.add_argument("--tenant-jwt", help="Tenant JWT to verify against the daroja-tenancy broker")
    ev.add_argument("--audience", help="Expected audience for the tenant JWT")
    ev.add_argument("--counterparty-id", help="Direct tenant triple: counterparty id (no-JWT path)")
    ev.add_argument("--client-id", help="Direct tenant triple: client id (no-JWT path)")
    ev.add_argument("--project-id", help="Direct tenant triple: project id (no-JWT path)")

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
        broker = os.environ.get("TENANCY_BROKER_URL", "").strip()
        consent_wired = bool(
            args.consent_file or os.environ.get("PREFLIGHT_CONSENT_FILE", "").strip()
        )
        posture_wired = bool(
            args.posture_file or os.environ.get("PREFLIGHT_POSTURE_FILE", "").strip()
        )
        print(f"preflight-gate: registry={registry_path} principals={len(principals)}")
        print(f"preflight-gate: tenant-broker={'wired' if broker else 'unwired (check skipped)'}")
        print(f"preflight-gate: consent-registry={'wired' if consent_wired else 'unwired (check skipped)'}")
        print(f"preflight-gate: posture-registry={'wired' if posture_wired else 'unwired (check skipped)'}")
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

    # P1: tenant-model check (active only when TENANCY_BROKER_URL wired).
    tenant = tenant_check(
        args.tenant_jwt,
        args.audience,
        args.counterparty_id,
        args.client_id,
        args.project_id,
    )
    decision["tenant"] = tenant["status"]
    if tenant.get("triple"):
        decision["triple"] = tenant["triple"]
    # Attribution passed but tenant context missing/invalid => fail-closed.
    if decision["decision"] == "allow" and tenant["status"] in ("invalid", "missing"):
        decision["decision"] = "reject"
        decision["reason"] = tenant["reason"]

    # P2: capability-consent check (active only when registry wired).
    consent_wired = bool(any([args.consent_file, os.environ.get("PREFLIGHT_CONSENT_FILE", "").strip()]))
    consent_registry: dict[str, Any] | None = None
    if consent_wired:
        try:
            consent_registry = load_consent(args.consent_file)
        except (OSError, ValueError) as e:
            print(f"preflight-gate: ERROR loading consent registry: {e}", file=sys.stderr)
            consent = {"status": "invalid", "reason": "consent-registry-unavailable"}
            decision["consent"] = consent["status"]
            decision["decision"] = "reject"
            decision["reason"] = consent["reason"]
            _emit(decision, args.event_log)
            print(json.dumps(decision))
            return 2
    consent = consent_check(args.capability, args.agent_id, consent_registry)
    decision["consent"] = consent["status"]
    if decision["decision"] == "allow" and consent["status"] in ("missing", "revoked", "invalid"):
        decision["decision"] = "reject"
        decision["reason"] = consent["reason"]

    # P3: routing-posture check (active only when registry wired).
    posture_wired = bool(any([args.posture_file, os.environ.get("PREFLIGHT_POSTURE_FILE", "").strip()]))
    posture_registry: dict[str, Any] | None = None
    if posture_wired:
        try:
            posture_registry = load_posture(args.posture_file)
        except (OSError, ValueError) as e:
            print(f"preflight-gate: ERROR loading posture registry: {e}", file=sys.stderr)
            posture = {"status": "invalid", "reason": "posture-registry-unavailable"}
            decision["posture"] = posture["status"]
            decision["decision"] = "reject"
            decision["reason"] = posture["reason"]
            _emit(decision, args.event_log)
            print(json.dumps(decision))
            return 2
    posture = posture_check(args.route, args.agent_id, posture_registry)
    decision["posture"] = posture["status"]
    if decision["decision"] == "allow" and posture["status"] in ("missing", "invalid"):
        decision["decision"] = "reject"
        decision["reason"] = posture["reason"]

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