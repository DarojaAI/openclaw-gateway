# preflight-emitter

Runtime seam for [`docs/contracts/preflight-v1.md`](../../docs/contracts/preflight-v1.md)
§"Runtime-hook invocation example (P4 rollout)".

The contract originally named a `before_route_inbound_message` gateway hook.
That surface does not exist upstream (0 hits through 2026.10.8; proposal
[openclaw/openclaw#176299](https://github.com/openclaw/openclaw/issues/176299)
is open). Upstream **did** ship a typed plugin-hooks API with an equivalent
gate: `before_agent_run` ("Inspect prompt and session messages before model
submission"; run is blocked on handler error/timeout). This extension is the
shipped seam.

## What it does

Per run **with a channel sender** (`event.senderId` present — i.e. an actual
inbound message), it executes the deployed shim:

```
~/.openclaw/scripts/remote/preflight-before-route-inbound-message.sh
```

with `ACTOR=<senderId>` and `AGENT=<ctx.agentId>` in the environment. The shim
invokes `preflight-gate.py evaluate`, which appends the
`preflight.decision.v1` telemetry event to `PREFLIGHT_EVENT_LOG` — the plugin
never writes audit records itself (contract §Event).

Exit mapping (contract §Decision + exit codes):

| Shim exit | Plugin outcome |
|---|---|
| 0 | `{outcome: "pass"}` — run proceeds |
| any non-zero | `{outcome: "block", reason: "preflight-exit-<code>"}` — fail-closed |

Runs **without** a sender (heartbeat, cron, subagent-internal turns) are not
inbound messages and pass ungated. Set
`PREFLIGHT_EMITTER_ENFORCE_WITHOUT_SENDER=1` in the gateway environment to
gate those too (they will fail P0 attribution and be rejected — know what you
are switching on before using it).

If the shim is missing or not executable, the plugin is **inert** (passes,
records nothing) — the contract's degradation path for unwired runtimes.

## Install (VM)

```bash
openclaw plugins install --link /opt/openclaw-gateway/extensions/preflight-emitter --force
openclaw plugins enable preflight-emitter
```

Merge into `openclaw.json` (conversation-hook grant is required for
`before_agent_run` on non-bundled plugins):

```json
{
  "plugins": {
    "entries": {
      "preflight-emitter": {
        "enabled": true,
        "hooks": { "allowConversationAccess": true }
      }
    }
  }
}
```

Reload and verify:

```bash
openclaw plugins reload preflight-emitter
openclaw plugins inspect preflight-emitter --runtime --json
```

Smoke: send a channel message to a pilot agent, then check the decision log:

```bash
tail -1 ~/.openclaw/preflight/production/preflight-decisions.jsonl
```

Every decision (allow and reject) must appear there. `PREFLIGHT_GATE` and
`PREFLIGHT_*_FILE` env come from the gateway service env written by the seed
deploy (`scripts/remote/write-preflight-env.sh`).
