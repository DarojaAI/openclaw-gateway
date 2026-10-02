# Contract: preflight-v1 — per-invocation pre-LLM gate

Part of epic `DarojaAI/linux-desktop-seed#1857` (owner `linux_desktop_seed`).
Work item: `DarojaAI/openclaw-gateway#119` (P0). Origin ask: `#106`
(L-001 §9.5 day-one binding gate, decision COMMITTED 2026-10-02).

This contract defines the wire surface for the per-invocation runtime
pre-flight gate: the deterministic, observable, pre-LLM-call check that
every invocation passes through before any LLM call lands.

## Scope (P0 + P1)

- **P0 — Operator-attribution** — the invocation's `actor` must resolve
  to a known principal (id or `@handle` in the principals registry).
- **P0 — Structured telemetry** — every decision (allow / reject /
  modify) emits one `preflight.decision.v1` event.
- **P0 — Deterministic allow/reject** surface with process exit codes
  the hook layer can act on.
- **P1 — Tenant-model validation** — when `TENANCY_BROKER_URL` is wired,
  the invocation's tenant context must be present and consistent with
  the daroja-tenancy round-2 contract (`counterparty_id` /
  `client_id` / `project_id` triple, verified against
  `POST /auth/verify`). Missing/invalid context rejects fail-closed.
  When unwired, the check is `skipped` (recorded in the event) so
  environments without tenancy keep working.

Later phases of epic #1857 add checks without changing the wire format:
P2 capability-consent (L-001 §3), P3 routing-posture (L-001 §6).

## Invocation (hook entry point)

```
preflight-gate.py evaluate --actor <x> --agent <y> [--capability <z>] \
    [--tenant-jwt <jwt>] [--audience <a>] \
    [--counterparty-id <c> --client-id <c> --project-id <p>] \
    [--principals <file>] [--event-log <file>]
```

`--actor` is the invoking principal (id or `@handle`). `--agent` is the
target agent id. `--capability` is informational in P0.

P1 tenant context: pass the tenant JWT (`--tenant-jwt`, optionally with
`--audience` for the expected-audience check) to verify against the
broker; or pass the direct triple (`--counterparty-id --client-id
--project-id`) for the presence-only path. When `TENANCY_BROKER_URL` is
set and neither is supplied, the invocation rejects as
`tenant-context-missing`.

## Decision + exit codes

| Exit | Meaning | Notes |
|------|---------|-------|
| 0 | ALLOW | actor known, agent present |
| 1 | REJECT | actor missing/unknown, or agent missing — fail-closed |
| 2 | CONFIG/USAGE error | registry unavailable/invalid — also fail-closed |

The hook layer must treat **any non-zero exit as a block**. Missing or
unknown attribution always rejects; a missing/invalid registry rejects
too (never allow-everything).

## Event (telemetry)

One JSON object per invocation, on stdout and (when configured) appended
to the event log:

```json
{"event": "preflight.decision.v1", "timestamp": "<ISO-8601 Z>",
 "agentId": "...", "actor": "...", "capability": "...",
 "decision": "allow"|"reject", "reason": "<machine-readable>",
 "principalKnown": true|false}
```

`reason` values in P0: `actor-missing`, `agent-missing`, `actor-unknown`,
`actor-known`, `registry-unavailable`.

## Principals registry

`config/preflight-principals.json` in the repo checkout:

```json
{"version": 1, "principals": [{"id": "...", "handle": "@..."}]}
```

Overridden at runtime with `--principals <file>` or
`PREFLIGHT_PRINCIPALS_FILE` so the deploy pipeline injects
environment-specific principal ids without hardcoding them in the
canonical config (DAT contract).

## Subscription surface (P1+ consumers)

- **Audit / incident forensics** — the event stream is the
  who-did-what-when record; a reject with `reason` is the "what did the
  gate say at T−5 min" query.
- **Cost/spend attribution** — paired with the per-agent OpenRouter
  child keys (openrouter-provision), reject events bound token spend
  that never happened.
- **Handoff thresholds** — `agent-handoff-thresholds.md` §4/§5 triggers
  can key off `capability`-scoped rejects (P2 capability-consent makes
  this concrete).

## Versioning

Bumping to preflight-v2 requires a written migration in
`docs/contracts/preflight-v2.md`; v1 consumers keep working.