# pr-gate (vendor overlay)

DarojaAI PR-closeout enforcement per RFC `DarojaAI/.github#33`.

## What this is

A **vendor overlay** extension that lives alongside the runtime binary
in `~/.openclaw/extensions/pr-gate/`. It depends on the upstream OpenClaw
runtime exposing `registerMessageSendingGate(...)` (or equivalent
pre-send hook). Until that hook lands upstream, this extension is a no-op
carrier; once it lands, this extension is what enforces the rule.

This is the *consumer* side; the runtime-API side is tracked in
`DarojaAI/.github#33` and contributed against `openclaw/openclaw`.

## Why a vendor overlay

The deploy ecosystem has three repos that *could* host OpenClaw extensions:
- `linux-desktop-seed` (L3a orchestrator)
- `openclaw-gateway` (L3b agent platform)
- `linux-headless-setup` (L2 OS bootstrap)

The orth-level RFC matrix (`DarojaAI/.github#35`) places
*runtime-patches-vendored-at-deploy-time* in `linux-desktop-seed/extensions/`
(L3a). This PR lands the pr-gate source there. The companion install
step in `linux-desktop-seed/scripts/install/openclaw-install.sh` is
**not yet shipped** and is separately tracked.

## Detection

- Green-claim phrases (default: `CI green`, `ready for review`,
  `ready for your approval`, `expected green`).
- PR references in message body via `#N` or `pull/N`.
- If no PR reference → block with `GREEN_CLAIM_NO_PR_REFERENCE`.
- If no fresh `gh pr checks <n>` observation → block with `GREEN_CLAIM_NO_CHECK_EVIDENCE`.
- If checks don't all `PASS` → block with `GREEN_CLAIM_CHECK_NOT_PASS`.

## Why NOT `openclaw-gateway/config/extensions/`

The extension is consumable code, not platform config. Operational
state (default phrases, ttl, gh-binary path) can be lifted into
`openclaw-gateway/config/` once the install hook ships; the source
stays here in L3a per the orth-level destination matrix.

## Constraints (v1)

- The extension does not spawn its own `gh` process. Verification of
  `gh pr checks <n>` happens via the agent-side tooling that observes
  the gate's blocking message and resumes the send. This keeps the
  extension process from needing its own PAT.
- Default-allow when no green-claim phrase is detected.
- No state persists process-local. Behaviour is identical on
  extension reload, agent restart, or VM reboot.
- The gate API dependency (`registerMessageSendingGate`) is the
  upstream patch tracked in `DarojaAI/.github#33`. Until it lands in
  the binary your deployments ship, pr-gate is a no-op carrier.

## Related

- `DarojaAI/.github#33` — RFC body
- `DarojaAI/.github#35` — orth-level destination-matrix RFC
- `DarojaAI/darojaai_architect/MEMORY.md` Lessons #63–#66 — destination-fork
  episode that pinned this layer as the right home

## Plan reference

Operator correction (Discord, 2026-08-21 21:19Z): "the ecosystem of
linux-desktop-seed + linux-headless-setup + openclaw-gateway should
present plenty of options." Lessons #63–#66 flipped the architect's
own operating discipline so the next instance of destination
misdirection will be caught before PR-creation.
