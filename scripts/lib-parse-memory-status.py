#!/usr/bin/env python3
# scripts/lib-parse-memory-status.py
#
# Pure decision logic for the post-deploy memory-index gate.
# Reads the JSON output of `openclaw memory status --json` from stdin
# and emits one TSV row per agent to stdout.
#
# Output columns (TAB-separated):
#   agent_id<TAB>verdict<TAB>reason
#
# Verdicts:
#   ok            — indexIdentity.status == "ok"
#   warn-swap     — active provider ≠ requestedProvider (model swap)
#   fail          — indexIdentity.status ∈ {missing, mismatch}
#                   AND the agent has data that should be indexed
#   warn-fresh    — indexIdentity.status ∈ {missing, mismatch}
#                   AND no data has been indexed yet (first-use will
#                   build the index)
#   warn-unknown  — indexIdentity.status is something we don't recognize
#                   (forward-compatible: don't fail, just surface)
#
# Exit codes:
#   0 — at least one row was emitted
#   3 — JSON parse error (caller should exit 2)
#   4 — no agents in the response (caller should exit 0 with a warning,
#       since an empty agent list means the memory subsystem is fresh
#       and there is nothing to verify)
#
# Why a separate file:
# - Matches the existing pattern (see lib-extract-wedged-lanes.py).
# - Keeps the bash side trivial (pipe + read TSV).
# - Lets BATS tests exercise the decision logic directly without
#   spawning a shell.
#
# Refs:
#   DarojaAI/openclaw-gateway#21
#   openclaw/openclaw#90361
#   openclaw/openclaw#90453

import json
import sys


def main() -> int:
    try:
        agents = json.load(sys.stdin)
    except Exception as exc:  # noqa: BLE001
        print(f"PARSE_ERROR\t{exc}", file=sys.stderr)
        return 3

    if not isinstance(agents, list) or not agents:
        print("NO_AGENTS\tnone\tnone", file=sys.stderr)
        return 4

    for entry in agents:
        agent_id = entry.get("agentId", "<unknown>")
        status = entry.get("status", {}) or {}
        scan = entry.get("scan", {}) or {}
        identity = (status.get("custom", {}) or {}).get("indexIdentity", {}) or {}
        identity_status = identity.get("status", "unknown")
        identity_reason = identity.get("reason", "")
        chunks = int(status.get("chunks", 0) or 0)
        files = int(status.get("files", 0) or 0)
        provider = status.get("provider", "")
        requested = status.get("requestedProvider", "")
        scan_total = int(scan.get("totalFiles", 0) or 0)

        has_data = chunks > 0 or files > 0 or scan_total > 0

        # Provider swap signal: the active provider does not match the
        # one the index was built for. This is the "model was swapped
        # out from under the index" failure mode.
        if provider and requested and provider != requested:
            print(
                f"{agent_id}\twarn-swap\t"
                f"provider={provider} requested={requested} chunks={chunks}"
            )
            continue

        if identity_status == "ok":
            print(f"{agent_id}\tok\tchunks={chunks} provider={provider}")
            continue

        if identity_status in ("missing", "mismatch"):
            if has_data:
                print(
                    f"{agent_id}\tfail\t"
                    f"identity={identity_status} reason={identity_reason!r} "
                    f"chunks={chunks} files={files}"
                )
            else:
                print(
                    f"{agent_id}\twarn-fresh\t"
                    f"identity={identity_status} chunks=0 "
                    f"(no data yet — first-use will rebuild)"
                )
            continue

        # Unknown identity state: don't fail, but warn.
        print(
            f"{agent_id}\twarn-unknown\t"
            f"identity={identity_status} reason={identity_reason!r}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
