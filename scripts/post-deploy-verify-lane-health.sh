#!/usr/bin/env bash
# scripts/post-deploy-verify-lane-health.sh
#
# Post-deploy health gate: refuses to declare a deploy healthy if any
# agent lane is currently wedged.
#
# Called at the end of scripts/install/deploy.sh (via L3a's deploy
# pipeline). Reads the gateway user journal for the last 60 seconds;
# if any `long-running session` event with `recovery=none` and age >
# 90s is present, exits 1 to fail the deploy gate.
#
# Why this exists:
# The deploy pipeline's existing health check pings /healthz and checks
# the gateway process is up. But it does not look at lane health — a
# freshly-deployed gateway can be "up" while still carrying a wedged lane
# from the prior run. Failing the deploy gate forces the operator to
# either (a) restart the gateway cleanly or (b) acknowledge the lane
# wedge and remediate.
#
# Exit codes:
#   0 = no wedged lanes in last 60s
#   1 = wedged lane(s) detected (deploy gate fails)
#   2 = probe itself failed (cannot read journal, openclaw not on PATH)
#
# Env:
#   GATEWAY_UNIT       systemd unit name (default: openclaw-gateway.service)
#   WINDOW_SECONDS     lookback window (default: 60)
#   FAIL_ON_HEALTHZ_DOWN  if "1", also require /healthz to be 200
#                        (default: 0 — the L3 deploy already checks healthz)
#   LANE_HEALTH_BUDGET_SECONDS  wall-clock threshold (default: 90)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GATEWAY_UNIT="${GATEWAY_UNIT:-openclaw-gateway.service}"
WINDOW_SECONDS="${WINDOW_SECONDS:-60}"
FAIL_ON_HEALTHZ_DOWN="${FAIL_ON_HEALTHZ_DOWN:-0}"
LANE_HEALTH_BUDGET_SECONDS="${LANE_HEALTH_BUDGET_SECONDS:-90}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [post-deploy-verify-lane-health] $*" >&2; }

# Healthz: optional, off by default since L3 deploys already check it.
if [[ "$FAIL_ON_HEALTHZ_DOWN" == "1" ]] && command -v curl >/dev/null 2>&1; then
    if ! curl -fsS --max-time 5 http://127.0.0.1:18789/healthz >/dev/null 2>&1; then
        log "FAIL: /healthz is not 200"
        exit 1
    fi
fi

# Lane check: scan the user journal for the lookback window.
if ! command -v journalctl >/dev/null 2>&1; then
    log "WARN: journalctl not available; cannot verify lane health"
    exit 2
fi

recent="$(journalctl --user -u "$GATEWAY_UNIT" --since "${WINDOW_SECONDS} seconds ago" \
    --no-pager -q 2>/dev/null || true)"

if [[ -z "$recent" ]]; then
    log "OK: no gateway log entries in last ${WINDOW_SECONDS}s (gateway idle or down)"
    exit 0
fi

# Parse `long-running session` events with age > budget.
# The lib honors WEDGED_MIN_AGE_SECONDS so we export it via `env` to
# propagate across the pipe into the python stage.
wedged="$(env WEDGED_MIN_AGE_SECONDS="$LANE_HEALTH_BUDGET_SECONDS" \
    bash -c 'echo "$1" | python3 "$2"' _ "$recent" \
    "$REPO_ROOT/scripts/lib-extract-wedged-lanes.py" \
    | python3 -c '
import json
import os
import sys
recovery_filter = os.environ.get("RECOVERY_FILTER", "none")
for line in sys.stdin:
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("recovery") != recovery_filter:
        continue
    sk = d["sessionKey"]
    age = d["ageSeconds"]
    rec = d["recovery"]
    print("%s age=%ds recovery=%s" % (sk, age, rec))
' || true)"

if [[ -n "$wedged" ]]; then
    log "FAIL: wedged lane(s) detected in last ${WINDOW_SECONDS}s:"
    echo "$wedged" | sed 's/^/  /' >&2
    log "Remediation: restart the gateway cleanly, then re-run deploy."
    exit 1
fi

log "OK: no wedged lanes in last ${WINDOW_SECONDS}s"
exit 0
