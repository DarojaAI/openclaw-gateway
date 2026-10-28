// preflight-emitter — runtime seam for docs/contracts/preflight-v1.md §P4.
//
// The contract's `before_route_inbound_message` gateway hook does not exist
// upstream (0 hits through 2026.10.8; proposal openclaw/openclaw#176299 is
// open). Upstream DID ship a typed plugin-hooks API with an equivalent gate
// surface: `before_agent_run` ("Inspect prompt and session messages before
// model submission"; blocks on thrown error or timeout). This extension is
// the shipped seam: per sender-attributed run it invokes the deployed
// preflight shim (the seed-side implementation of the contract pseudocode)
// and maps the gate exit code onto the run outcome.
//
// Contract invariants honored here:
//   - The gate itself appends the `preflight.decision.v1` event to
//     PREFLIGHT_EVENT_LOG; this plugin NEVER synthesizes an audit record.
//   - ANY non-zero shim exit blocks the run (0 = allow, 1 = gate reject,
//     2 = config error — also fail-closed).
//   - Unwired runtime (shim not deployed / not executable) stays inert: the
//     plugin passes and records nothing, mirroring the shim's own
//     degradation path. Wiring must never fail traffic on unwired runtimes.
//
// Scope: the contract gates INBOUND messages. Runs without a channel sender
// (heartbeat, cron, subagent-internal turns) are not inbound messages and
// stay ungated unless PREFLIGHT_EMITTER_ENFORCE_WITHOUT_SENDER=1 is set in
// the gateway environment.
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { execFile } from "node:child_process";
import { access, constants } from "node:fs/promises";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

type AgentRunEvent = { senderId?: string };
type AgentRunCtx = { agentId?: string };
type GateOutcome = { outcome: "pass" } | { outcome: "block"; reason: string; message?: string; category?: string };

const shimPath = (): string =>
  `${process.env.HOME ?? ""}/.openclaw/scripts/remote/preflight-before-route-inbound-message.sh`;

/** Shim exit code; non-number codes (timeout/kill/unknown) map to the config-error class. */
const exitCodeOf = (err: unknown): number => {
  if (err !== null && typeof err === "object" && "code" in err) {
    const code: unknown = err.code;
    if (typeof code === "number") return code;
  }
  return 2;
};

export default definePluginEntry({
  id: "preflight-emitter",
  name: "Preflight Emitter",
  description:
    "Per-invocation preflight gate emission (contract preflight-v1 P4): runs the deployed preflight shim before any LLM call and blocks on any non-zero gate exit.",
  register(api) {
    api.on(
      "before_agent_run",
      async (event: AgentRunEvent, ctx: AgentRunCtx): Promise<GateOutcome | void> => {
        const enforceWithoutSender =
          process.env.PREFLIGHT_EMITTER_ENFORCE_WITHOUT_SENDER === "1";
        if (event.senderId === undefined && !enforceWithoutSender) {
          return; // not an inbound message: outside contract scope
        }
        const shim = shimPath();
        try {
          await access(shim, constants.X_OK);
        } catch {
          return; // unwired runtime: shim absent -> inert (contract degradation path)
        }
        try {
          await execFileP("bash", [shim], {
            env: { ...process.env, ACTOR: event.senderId ?? "", AGENT: ctx.agentId ?? "" },
            timeout: 10_000,
          });
          return { outcome: "pass" };
        } catch (err) {
          const code = exitCodeOf(err);
          return {
            outcome: "block",
            reason: `preflight-exit-${code}`,
            message: "Invocation blocked by the preflight gate.",
            category: "preflight",
          };
        }
      },
    );
  },
});
