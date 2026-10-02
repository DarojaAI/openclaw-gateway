# Example pre-flight registries — EXAMPLE DATA, NOT PRODUCTION

Registry examples for the per-invocation pre-flight gate
(`scripts/preflight-gate.py`, contract `docs/contracts/preflight-v1.md`,
epic `DarojaAI/linux-desktop-seed#1857`, P4.2 =
`DarojaAI/openclaw-gateway#127`).

Every value here is a placeholder: `@example-operator-*` ids,
`EXAMPLE-*` tenant ids, one granted + one revoked capability per agent.
They exist so an operator can see the gate work end-to-end before
wiring real environment data. Each file also carries an inline
`_note` marker so the example status travels with any copy.

## Files

- `principals.example.json` — P0 operator-attribution registry (what
  the gate matches `--actor` against).
- `consent.example.json` — P2 capability-consent registry (L-001 §3):
  `granted`/`revoked` capability per agent.
- `posture.example.json` — P3 routing-posture registry (L-001 §6):
  active route set per agent.

Pilot agent set covered: `daroja-lawyer-agent`, `daroja-finance-agent`,
and the infra lane `linux_desktop_seed`. Each agent carries one granted
capability + one revoked capability and an explicit route set, so both
allow and reject outcomes reproduce out of the box.

## Operator workflow (per environment)

1. Copy each `*.example.json` to the environment's registry path
   (e.g. `/etc/daroja/preflight/<name>.json`).
2. Replace the EXAMPLE values with the environment's real operator
   ids/handles, capability grants, and active routing-matrix rows.
3. Point the gate at the copies via env injection (DAT contract —
   canonical `config/preflight-*.json` stay empty templates):

   ```bash
   export PREFLIGHT_PRINCIPALS_FILE=/etc/daroja/preflight/principals.json
   export PREFLIGHT_CONSENT_FILE=/etc/daroja/preflight/consent.json
   export PREFLIGHT_POSTURE_FILE=/etc/daroja/preflight/posture.json
   ```

4. Smoke the wiring:

   ```bash
   python3 scripts/preflight-gate.py --check    # expect exit 0
   ```

5. Run one allow + one reject against the copied registries — the exact
   commands and expected events are in
   `docs/contracts/preflight-v1.md` § "Runtime-hook invocation example",
   pinned by `tests/preflight-examples.bats`.
