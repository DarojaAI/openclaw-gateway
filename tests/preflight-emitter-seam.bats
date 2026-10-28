#!/usr/bin/env bats
# Seam tests for extensions/preflight-emitter (contract preflight-v1 P4).
# Static, deterministic assertions — no gateway runtime required.

PLUGIN="extensions/preflight-emitter"
CONTRACT="docs/contracts/preflight-v1.md"

@test "preflight-emitter: plugin files exist and manifest is valid JSON" {
  [ -f "$PLUGIN/index.ts" ]
  [ -f "$PLUGIN/package.json" ]
  [ -f "$PLUGIN/openclaw.plugin.json" ]
  jq empty "$PLUGIN/package.json" "$PLUGIN/openclaw.plugin.json"
}

@test "preflight-emitter: registers the real before_agent_run gate hook" {
  # Contract amendment 2026-10-28: the seam is the upstream typed plugin hook,
  # not the nonexistent before_route_inbound_message gateway surface.
  # (Negative greps run on comment-stripped code; docs may mention the name.)
  grep -q '"before_agent_run"' "$PLUGIN/index.ts"
  ! grep -v '^\s*//' "$PLUGIN/index.ts" | grep -q 'before_route_inbound_message'
}

@test "preflight-emitter: invokes the deployed seed shim, never synthesizes audit records" {
  # Contract §Event: the GATE appends preflight.decision.v1; the hook must not.
  grep -q 'preflight-before-route-inbound-message.sh' "$PLUGIN/index.ts"
  ! grep -v '^\s*//' "$PLUGIN/index.ts" | grep -q 'preflight.decision.v1'
}

@test "preflight-emitter: blocks on ANY non-zero gate exit (fail-closed)" {
  grep -q 'outcome: "block"' "$PLUGIN/index.ts"
  grep -q 'preflight-exit-' "$PLUGIN/index.ts"
  grep -q 'const exitCodeOf' "$PLUGIN/index.ts"
}

@test "preflight-emitter: inert on unwired runtimes (shim absent -> pass, no record)" {
  grep -q 'constants.X_OK' "$PLUGIN/index.ts"
  grep -q 'unwired runtime' "$PLUGIN/index.ts"
}

@test "preflight-emitter: sender-scoped by default, heartbeat/cron turns ungated" {
  grep -q 'senderId === undefined' "$PLUGIN/index.ts"
  grep -q 'PREFLIGHT_EMITTER_ENFORCE_WITHOUT_SENDER' "$PLUGIN/index.ts"
}

@test "preflight-emitter: shim reference resolves in the seed deploy layout" {
  # The shim is shipped by linux-desktop-seed copy-deploy-artifacts phase 3 to
  # ~/.openclaw/scripts/remote/ — assert the plugin path matches that layout.
  grep -q '.openclaw/scripts/remote/preflight-before-route-inbound-message.sh' "$PLUGIN/index.ts"
}

@test "preflight-emitter: contract documents the shipped seam" {
  grep -q 'before_agent_run' "$CONTRACT"
  grep -q 'preflight-emitter' "$CONTRACT"
}
