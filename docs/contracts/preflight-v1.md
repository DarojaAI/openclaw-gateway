# Contract: preflight-v1 — per-invocation pre-LLM gate

Part of epic `DarojaAI/linux-desktop-seed#1857` (owner `linux_desktop_seed`).
Work item: `DarojaAI/openclaw-gateway#119` (P0). Origin ask: `#106`
(L-001 §9.5 day-one binding gate, decision COMMITTED 2026-10-02).

This contract defines the wire surface for the per-invocation runtime
pre-flight gate: the deterministic, observable, pre-LLM-call check that
every invocation passes through before any LLM call lands.

## Scope (P0 + P1 + P2)

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
- **P2 — Capability-consent (L-001 §3)** — when a consent registry is
  wired (`PREFLIGHT_CONSENT_FILE` set or `--consent-file` given), the
  requested capability must resolve to an explicit `granted` record for
  the agent. No capability, no record, or a `revoked` record rejects
  fail-closed — silent capability introductions are blocked pre-flight.
  When unwired, the check is `skipped` (recorded in the event) so
  environments without the consent layer keep P0/P1 behavior.
- **P3 — Routing-posture (L-001 §6)** — when a posture registry is
  wired (`PREFLIGHT_POSTURE_FILE` set or `--posture-file` given), the
  invocation's route must be in the agent's active routing-matrix set.
  No route, agent with no route set, or a route outside the active set
  rejects fail-closed. When unwired, the check is `skipped` (recorded
  in the event) so environments without the posture layer keep
  P0/P1/P2 behavior.

Later phases of epic #1857 add features without changing the wire
format (P4 is the downstream rollout of these checks).

## Invocation (hook entry point)

```
preflight-gate.py evaluate --actor <x> --agent <y> [--capability <z>] \
    [--route <r>] [--tenant-jwt <jwt>] [--audience <a>] \
    [--counterparty-id <c> --client-id <c> --project-id <p>] \
    [--consent-file <file>] [--posture-file <file>] [--principals <file>]
    [--event-log <file>]
```

`--actor` is the invoking principal (id or `@handle`). `--agent` is the
target agent id. `--capability` is the requested capability (enforced
by the P2 consent check when wired).

P1 tenant context: pass the tenant JWT (`--tenant-jwt`, optionally with
`--audience` for the expected-audience check) to verify against the
broker; or pass the direct triple (`--counterparty-id --client-id
--project-id`) for the presence-only path. When `TENANCY_BROKER_URL` is
set and neither is supplied, the invocation rejects as
`tenant-context-missing`.

P2 consent context: with a wired registry, `--capability` must resolve
to a `granted` record for `--agent`. Registry loading failure (wired but
missing/invalid file) exits 2 (config error, fail-closed).

P3 posture context: with a wired registry, `--route` must be in the
agent's active route set (`posture-active`). No route ⇒
`posture-route-missing`; agent with no route set ⇒ `posture-missing`;
route outside the set ⇒ `posture-mismatch`. All reject. Registry loading
failure (wired but missing/invalid file) exits 2 (config error,
fail-closed).

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
 "principalKnown": true|false,
 "tenant": "ok"|"invalid"|"missing"|"skipped",
 "consent": "ok"|"missing"|"revoked"|"invalid"|"skipped"}
```

`reason` values: `actor-missing`, `agent-missing`, `actor-unknown`,
`actor-known`, `registry-unavailable` (P0); `tenant-context-missing`,
`tenant-jwt-invalid`, `tenant-broker-unreachable`, `tenant-triple-present`,
`tenant-jwt-verified` (P1); `consent-capability-missing`,
`consent-missing`, `consent-revoked`, `consent-granted`,
`consent-registry-unavailable`, `consent-registry-unwired` (P2);
`posture-route-missing`, `posture-missing`, `posture-mismatch`,
`posture-active`, `posture-registry-unavailable`, `posture-registry-unwired`
(P3). `tenant`, `consent`, and `posture` fields are additive and
backward-compatible with P0 consumers.

## Principals registry

`config/preflight-principals.json` in the repo checkout:

```json
{"version": 1, "principals": [{"id": "...", "handle": "@..."}]}
```

Overridden at runtime with `--principals <file>` or
`PREFLIGHT_PRINCIPALS_FILE` so the deploy pipeline injects
environment-specific principal ids without hardcoding them in the
canonical config (DAT contract).

## Consent registry (P2)

`config/preflight-consent.json` in the repo checkout:

```json
{"version": 1, "consent": {"<agent_id>": {"<capability>": "granted"|"revoked"}}}
```

Wired with `PREFLIGHT_CONSENT_FILE` (env) or `--consent-file` (CLI).
Unwired ⇒ `consent: "skipped"` (P0/P1 behavior unchanged). Wired but
missing/invalid file ⇒ exit 2 (config error, fail-closed).

## Posture registry (P3)

`config/preflight-posture.json` in the repo checkout:

```json
{"version": 1, "posture": {"<agent_id>": ["<route>", ...]}}
```

The active routing-matrix route set per agent (L-001 §6). Wired with
`PREFLIGHT_POSTURE_FILE` (env) or `--posture-file` (CLI). Unwired ⇒
`posture: "skipped"` (P0/P1/P2 behavior unchanged). Wired but
missing/invalid file ⇒ exit 2 (config error, fail-closed).

## Runtime-hook invocation example (P4 rollout)

P4 downstream rollout wiring: a `before_route_inbound_message` runtime
hook calls `evaluate` once per inbound message, before any LLM call
lands, and maps the exit code onto the invocation outcome. The examples
below run against the EXAMPLE registries in
`config/examples/preflight/` (pilot agent set: `daroja-lawyer-agent`,
`daroja-finance-agent`, infra lane `linux_desktop_seed`) — placeholder
data the deploy operator copies per environment and fills with real
env-specific values (DAT contract: canonical `config/preflight-*.json`
stay empty templates; env-specific paths are injected at deploy).

### Deploy wiring (env injection)

```bash
export PREFLIGHT_PRINCIPALS_FILE=/etc/daroja/preflight/principals.json
export PREFLIGHT_CONSENT_FILE=/etc/daroja/preflight/consent.json
export PREFLIGHT_POSTURE_FILE=/etc/daroja/preflight/posture.json
export PREFLIGHT_EVENT_LOG=/var/log/daroja/preflight-decisions.jsonl
export TENANCY_BROKER_URL="https://tenancy.example.internal"  # optional; unset => tenant check skipped
```

### Hook pseudocode

```bash
before_route_inbound_message() {
    # Hook context from the inbound message envelope:
    #   ACTOR      invoking principal (id or @handle)
    #   AGENT      target agent id
    #   CAPABILITY requested capability
    #   ROUTE      routing-matrix route (L-001 §6)
    #   TENANT_*   tenant triple (counterparty/client/project)
    python3 scripts/preflight-gate.py evaluate \
        --actor "$ACTOR" \
        --agent "$AGENT" \
        --capability "$CAPABILITY" \
        --route "$ROUTE" \
        --counterparty-id "$TENANT_COUNTERPARTY_ID" \
        --client-id "$TENANT_CLIENT_ID" \
        --project-id "$TENANT_PROJECT_ID"
    case $? in
        0) ;;                                      # ALLOW -> proceed to the LLM call
        1) reject_invocation "preflight" ;;        # gate reject -> block the invocation
        2) reject_invocation "preflight-config"    # config error -> block + alert operator
           alert_operator ;;
    esac
}
```

Exit-code handling: the hook treats **any non-zero exit as a block**
(0 = allow, 1 = gate reject, 2 = registry/config error — also
fail-closed). The `preflight.decision.v1` event is emitted by the gate
on every decision and appended to `PREFLIGHT_EVENT_LOG`, so the hook
never needs to synthesize its own audit record.

### Worked examples against the example registries

For a local run against the repo examples, point the env vars at the
example files:

```bash
export PREFLIGHT_PRINCIPALS_FILE=$PWD/config/examples/preflight/principals.example.json
export PREFLIGHT_CONSENT_FILE=$PWD/config/examples/preflight/consent.example.json
export PREFLIGHT_POSTURE_FILE=$PWD/config/examples/preflight/posture.example.json
```

`--check` (operator smoke, exit 0):

```console
$ python3 scripts/preflight-gate.py --check
preflight-gate: registry=.../config/examples/preflight/principals.example.json principals=2
preflight-gate: tenant-broker=unwired (check skipped)
preflight-gate: consent-registry=wired
preflight-gate: posture-registry=wired
```

**ALLOW** — known operator, granted capability, active route
(`TENANCY_BROKER_URL` unset in this example ⇒ `tenant: "skipped"`; when
wired, the same invocation verifies the triple against the broker):

```console
$ python3 scripts/preflight-gate.py evaluate \
      --actor @example-operator-0001 --agent daroja-lawyer-agent \
      --capability draft_redline --route legal_redline \
      --counterparty-id EXAMPLE-cp-001 \
      --client-id EXAMPLE-client-001 --project-id EXAMPLE-project-001
{"event": "preflight.decision.v1", "timestamp": "2026-10-02T19:23:30Z", "agentId": "daroja-lawyer-agent", "actor": "@example-operator-0001", "capability": "draft_redline", "decision": "allow", "reason": "actor-known", "principalKnown": true, "tenant": "skipped", "consent": "ok", "posture": "ok"}
# exit 0 -> hook proceeds to the LLM call
```

**REJECT** — capability revoked in the consent registry (L-001 §3):

```console
$ python3 scripts/preflight-gate.py evaluate \
      --actor @example-operator-0001 --agent daroja-lawyer-agent \
      --capability external_send --route legal_redline \
      --counterparty-id EXAMPLE-cp-001 \
      --client-id EXAMPLE-client-001 --project-id EXAMPLE-project-001
{"event": "preflight.decision.v1", "timestamp": "2026-10-02T19:23:30Z", "agentId": "daroja-lawyer-agent", "actor": "@example-operator-0001", "capability": "external_send", "decision": "reject", "reason": "consent-revoked", "principalKnown": true, "tenant": "skipped", "consent": "revoked", "posture": "ok"}
# exit 1 -> hook blocks the invocation
```

Other reject paths carry their own `reason` codes (`actor-unknown`,
`posture-mismatch`, `consent-missing`, …) per the event section above.
These exact invocations are pinned by `tests/preflight-examples.bats`
against the example registries, so the documented outcomes cannot drift
from the gate's behavior.

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