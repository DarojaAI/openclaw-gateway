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
#   INGRESS_FRESHNESS_SECONDS   fail if gateway up but no Discord receive
#                               within this many seconds (default: 900;
#                               0 disables). Issue #135.
#   INGRESS_FRESHNESS_MARKER    regex for a Discord receive/drain log line
#                               (default: see lib-last-ingress.py)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GATEWAY_UNIT="${GATEWAY_UNIT:-openclaw-gateway.service}"
WINDOW_SECONDS="${WINDOW_SECONDS:-60}"
FAIL_ON_HEALTHZ_DOWN="${FAIL_ON_HEALTHZ_DOWN:-0}"
LANE_HEALTH_BUDGET_SECONDS="${LANE_HEALTH_BUDGET_SECONDS:-90}"

# Ingress freshness (Issue #135): fail when the gateway shows recent log
# activity (it is up) but no successful Discord receive/drain happened
# within INGRESS_FRESHNESS_SECONDS (default 900 = 15 min). 0 disables this
# gate. INGRESS_FRESHNESS_MARKER overrides the line-matching regex (see
# lib-last-ingress.py); empty = library default.
INGRESS_FRESHNESS_SECONDS="${INGRESS_FRESHNESS_SECONDS:-900}"
INGRESS_FRESHNESS_MARKER="${INGRESS_FRESHNESS_MARKER:-}"

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
    | python3 "$REPO_ROOT/scripts/lib-filter-wedged-lanes.py" || true)"

if [[ -n "$wedged" ]]; then
    log "FAIL: wedged lane(s) detected in last ${WINDOW_SECONDS}s:"
    echo "$wedged" | sed 's/^/  /' >&2
    log "Remediation: restart the gateway cleanly, then re-run deploy."
    exit 1
fi

# Ingress freshness (Issue #135): a gateway can answer /healthz 200 while
# its Discord ingress is silently dead for hours. Failing only when the
# gateway provably produced logs in the ingress window avoids false-failing
# a *genuinely idle* fresh deploy (silent journal = treat as idle/down).
if [[ "$INGRESS_FRESHNESS_SECONDS" -gt 0 ]]; then
    ing_logs="$(journalctl --user -u "$GATEWAY_UNIT" \
        --since "${INGRESS_FRESHNESS_SECONDS} seconds ago" \
        --no-pager -q 2>/dev/null || true)"
    if [[ -n "$ing_logs" ]]; then
        ing_json="$(echo "$ing_logs" | \
            INGRESS_FRESHNESS_MARKER="$INGRESS_FRESHNESS_MARKER" \
            python3 "$REPO_ROOT/scripts/lib-last-ingress.py" || true)"
        ing_found="$(printf '%s' "$ing_json" | python3 -c 'import json,sys
try: print(1 if json.load(sys.stdin).get("found") else 0)
except Exception: print(0)' 2>/dev/null || echo 0)"
        ing_age="$(printf '%s' "$ing_json" | python3 -c 'import json,sys
try: print(int(json.load(sys.stdin).get("ageSeconds", -1)))
except Exception: print(-1)' 2>/dev/null || echo -1)"

        if [[ "$ing_found" == "1" ]] && [[ "$ing_age" -ge 0 ]] \
                && [[ "$ing_age" -lt $INGRESS_FRESHNESS_SECONDS ]]; then
            log "OK: last Discord receive ${ing_age}s ago (window=${INGRESS_FRESHNESS_SECONDS}s)"
        else
            if [[ "$ing_found" == "0" ]]; then
                log "FAIL: gateway log activity but no Discord receive/drain in last ${INGRESS_FRESHNESS_SECONDS}s (Issue #135)"
            else
                log "FAIL: last Discord receive ${ing_age}s ago (> window ${INGRESS_FRESHNESS_SECONDS}s) (Issue #135)"
            fi
            log "Remediation: verify the Discord gateway connection/token, then re-run deploy."
            exit 1
        fi
    else
        log "WARN: no gateway log activity in last ${INGRESS_FRESHNESS_SECONDS}s; skipping ingress freshness check"
    fi
fi

log "OK: no wedged lanes in last ${WINDOW_SECONDS}s"
exit 0
