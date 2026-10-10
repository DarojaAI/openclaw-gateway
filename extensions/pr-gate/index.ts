// pr-gate extension — DarojaAI PR-closeout enforcement.
//
// Implements RFC DarojaAI/.github#33 pre-send gate: rejects outbound
// message(send) calls that include a green-claim phrase (e.g. "CI green",
// "ready for review") when no fresh gh pr checks observation exists for
// the referenced PR.
//
// This is a vendor overlay shipped via linux-desktop-seed/extensions/ per
// DarojaAI/.github#35. It does NOT modify runtime source — it depends on
// the upstream OpenClaw registerMessageSendingGate API landing in the
// runtime via an upstream PR stream.

type GateContext = {
  to: string;
  content: string;
  channelId: string;
  accountId?: string;
  metadata?: Record<string, unknown>;
};

type GateDecision =
  | { allow: true }
  | { allow: false; reason: string; code?: string };

type GateHandlerFn = (ctx: GateContext) => Promise<GateDecision> | GateDecision;

type GateHost = {
  registerMessageSendingGate?: (handler: GateHandlerFn) => void;
};

// PR-GATE IS HOST-RESOLVED, NOT GLOBAL.
// Earlier revisions read a global openclaw symbol that the runtime
// supposedly injects on plugin load; the actual runtime never injects that
// global and the plugin loader aborts with ReferenceError: openclaw is not
// defined. We now resolve the gate host through a runtime module surface
// (with a global fallback for older runtimes) and degrade to a no-op
// carrier when no host is available. The plugin stays loadable on every
// supported runtime version; only the gate enforcement depends on the
// upstream API landing.
let gateHost: GateHost | null = null;
try {
  // The runtime publishes the gate surface behind @openclaw/host (see
  // DarojaAI/openclaw-gateway PR #70 if it lands; until then this
  // dynamic import silently fails and we degrade to a no-op carrier).
  const hostModule = "@openclaw/host";
  // @ts-expect-error — TS does not know about the runtime module; runtime provides.
  const mod = await import(/* @vite-ignore */ hostModule).catch(() => null);
  if (mod && typeof mod.registerMessageSendingGate === "function") {
    gateHost = mod as GateHost;
  } else if (
    typeof globalThis !== "undefined" &&
    (globalThis as { openclaw?: GateHost }).openclaw &&
    typeof (globalThis as { openclaw?: GateHost }).openclaw?.registerMessageSendingGate ===
      "function"
  ) {
    // Fallback for older runtimes that still expose the host on a global.
    gateHost = (globalThis as { openclaw?: GateHost }).openclaw ?? null;
  }
} catch {
  // No host available — fall through to the no-op carrier.
}

const DEFAULT_GREEN_CLAIM_PHRASES = [
  "CI green",
  "ready for review",
  "ready for your approval",
  "expected green",
];

const PR_REF_PATTERN = /(?:^|\W)(?:#|pull\/)(\d+)\b/;

function containsGreenClaim(content: string, phrases: string[]): boolean {
  const lower = content.toLowerCase();
  return phrases.some((phrase) => lower.includes(phrase.toLowerCase()));
}

function findPrReferences(content: string, pattern: RegExp): number[] {
  const matches = content.match(new RegExp(pattern.source, "g"));
  if (!matches) return [];
  const refs = new Set<number>();
  for (const m of matches) {
    const digits = m.match(/\d+/);
    if (!digits) continue;
    refs.add(Number(digits[0]));
  }
  return [...refs];
}

export const config = {
  greenClaimPhrases: DEFAULT_GREEN_CLAIM_PHRASES,
  prReferencePattern: PR_REF_PATTERN,
  // observationTtlMs is enforced by the extension host (openclaw-gateway's
  // extension-manager); we persist nothing process-local here so that the
  // gate behaviour is consistent across restart cycles.
};

async function verifyChecksForPr(_prNumber: number): Promise<{ passed: boolean } | null> {
  // Vendor-overlay approach: emit a "checks request" message back to the
  // agent asking the operator-side tooling to re-run gh pr checks <n>
  // rather than spawn it from inside the extension. The agent picks up
  // the request, runs the gh CLI, and resumes the message send. The
  // actual gate decision uses the agent TLS-authenticated gh session,
  // which avoids the extension process having to bundle its own PAT.
  //
  // For v1 we treat the absence of an observation as a block. A future
  // revision can wire the verification to the operator pre-send channel
  // so the gate can wait synchronously without keeping the result local.
  return null;
}

const handler: GateHandlerFn = async (ctx) => {
  if (!containsGreenClaim(ctx.content, config.greenClaimPhrases)) {
    return { allow: true };
  }
  const prNumbers = findPrReferences(ctx.content, config.prReferencePattern);
  if (prNumbers.length === 0) {
    return {
      allow: false,
      reason:
        "pr-gate: green-claim phrase detected but no PR reference (#N) was " +
        "found in the outbound message. Add a PR reference so the gate can " +
        "verify the claim.",
      code: "GREEN_CLAIM_NO_PR_REFERENCE",
    };
  }
  for (const prNumber of prNumbers) {
    const obs = await verifyChecksForPr(prNumber);
    if (!obs) {
      return {
        allow: false,
        reason:
          "pr-gate: green-claim phrase gated for PR #" +
          prNumber +
          " — no recent gh pr checks observation is available. Run " +
          "gh pr checks " +
          prNumber +
          " first, then retry the send.",
        code: "GREEN_CLAIM_NO_CHECK_EVIDENCE",
      };
    }
    if (!obs.passed) {
      return {
        allow: false,
        reason:
          "pr-gate: at least one required check is not PASS for PR #" +
          prNumber +
          ". Run gh pr checks " +
          prNumber +
          " and confirm all required contexts are PASS before retrying.",
        code: "GREEN_CLAIM_CHECK_NOT_PASS",
      };
    }
  }
  return { allow: true };
};

if (gateHost && typeof gateHost.registerMessageSendingGate === "function") {
  gateHost.registerMessageSendingGate(handler);
} else {
  // Fallback: extension loaded but the runtime lacks the gate API. The
  // companion RFC (DarojaAI/.github#33) tracks the upstream PR for the
  // gate API. Until that lands, pr-gate is a no-op carrier.
  console.warn(
    "[pr-gate] openclaw.registerMessageSendingGate is unavailable; this " +
      "extension will not gate outbound sends until the runtime hooks the API.",
  );
}
