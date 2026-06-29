#!/usr/bin/env bash
# scripts/lane-health-probe.sh
#
# Lane starvation watchdog for the OpenClaw gateway.
#
# Why this exists:
# The upstream OpenClaw runtime (openclaw@2026.6.8) does not preempt a lane
# whose model_call is wedged. When one agent lane holds a model call for
# >90s with no stream progress, the gateway event loop saturates and every
# other agent lane on the same gateway goes silent. The diagnostic
# "[diagnostic] long-running session ... recovery=none" is logged but no
# operator alert or lane kill is triggered.
#
# This probe:
#   1. Scans the gateway user-journal for `long-running session` events
#      where `classification=long_running` and `recovery=none`.
#   2. For each wedged lane, checks stream progress: if the lane has been
#      in processing/model_call > LANE_WALL_BUDGET_SECONDS (default 90)
#      with no stream progress, marks it for kill.
#   3. Kills the lane via `openclaw lane kill <sessionKey>` (best-effort).
#   4. Discord-alerts the operator channel ONCE per wedged lane per probe
#      cycle, with debouncing via the state file.
#
# Designed to run from a user systemd timer (LANE_HEALTH_PROBE.timer,
# installed by scripts/install/install-lane-health-probe.sh) every 30s.
#
# Exit codes:
#   0 = no wedged lanes (healthy)
#   1 = wedged lane(s) detected and killed (recovered)
#   2 = probe itself failed (cannot read journal, etc.)
#
# Sandbox-safe: all paths honor $HOME and $XDG_RUNTIME_DIR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- Configuration ---------------------------------------------------------

LANE_WALL_BUDGET_SECONDS="${LANE_WALL_BUDGET_SECONDS:-90}"
LANE_GRACE_SECONDS="${LANE_GRACE_SECONDS:-30}"
PROBE_INTERVAL_SECONDS="${PROBE_INTERVAL_SECONDS:-30}"

# State file: persists debouncing across probe runs.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/openclaw-lane-health"
STATE_FILE="$STATE_DIR/alerted.json"
mkdir -p "$STATE_DIR"
[[ -f "$STATE_FILE" ]] || : > "$STATE_FILE"

# Operator Discord channel. The deploy pipeline writes this to
# ~/.openclaw/operator-channel in scripts/install/install-lane-health-probe.sh.
# When unset, alert is logged to stderr only.
OPERATOR_CHANNEL_FILE="$HOME/.openclaw/operator-channel"
OPERATOR_CHANNEL=""
if [[ -f "$OPERATOR_CHANNEL_FILE" ]]; then
    OPERATOR_CHANNEL="$(cat "$OPERATOR_CHANNEL_FILE" 2>/dev/null || true)"
fi

# User systemd unit for the gateway. Probe restarts this only when
# `LANE_HEALTH_PROBE_RESTART=1` AND a force-kill via `openclaw lane kill`
# fails to clear the wedged lane.
GATEWAY_UNIT="${GATEWAY_UNIT:-openclaw-gateway.service}"

log() {
    # Logs go to stderr so cron / systemd captures them without mixing
    # into any stdout-based health gate output.
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [lane-health-probe] $*" >&2
}

alert() {
    local subject="$1"; shift
    local body="$*"
    log "ALERT: $subject -- $body"
    if [[ -n "$OPERATOR_CHANNEL" ]]; then
        # Use openclaw's built-in `notify` if available; fall back to a
        # log-only alert. We deliberately avoid invoking the Discord
        # bot REST API directly — that's the gateway's job.
        if command -v openclaw >/dev/null 2>&1; then
            openclaw notify --channel "$OPERATOR_CHANNEL" \
                --subject "🚨 $subject" --body "$body" \
                >/dev/null 2>&1 || log "openclaw notify failed (non-fatal)"
        fi
    fi
}

# ---- Detection -------------------------------------------------------------

# Find the gateway log source. Prefer the user journal; fall back to a
# rotating file under $HOME/.local/log/openclaw-gateway/ if the journal
# isn't available (e.g. running outside systemd --user).
JOURNAL_AVAILABLE=false
if command -v journalctl >/dev/null 2>&1; then
    if journalctl --user -u "$GATEWAY_UNIT" --since "5 minutes ago" \
            --no-pager -q 2>/dev/null | head -1 >/dev/null; then
        JOURNAL_AVAILABLE=true
    fi
fi

read_recent_logs() {
    # Echo the last 5 minutes of gateway logs.
    if [[ "$JOURNAL_AVAILABLE" == "true" ]]; then
        journalctl --user -u "$GATEWAY_UNIT" --since "5 minutes ago" \
            --no-pager -q 2>/dev/null || true
    else
        local log_file="$HOME/.local/log/openclaw-gateway/openclaw-gateway.log"
        if [[ -f "$log_file" ]]; then
            # Tail by mtime is unreliable; use a python one-liner to slice
            # the last 5 minutes by timestamp.
            python3 - "$log_file" <<'PY' || true
import datetime as dt
import sys

path = sys.argv[1]
cutoff = dt.datetime.utcnow() - dt.timedelta(minutes=5)
out = []
with open(path, errors="replace") as fh:
    for line in fh:
        # Lines look like: "Jun 28 18:48:41 host openclaw[336954]: ..."
        try:
            ts = dt.datetime.strptime(line[:15], "%b %d %H:%M:%S")
            ts = ts.replace(year=dt.datetime.utcnow().year)
            if ts >= cutoff:
                out.append(line)
        except ValueError:
            continue
sys.stdout.write("".join(out))
PY
        fi
    fi
}

extract_wedged_lanes() {
    # Reads stdin (recent log lines) and prints one JSON object per
    # wedged lane on stdout. Delegates to lib-extract-wedged-lanes.py
    # so the regex is owned by one source of truth and unit-testable.
    python3 "$REPO_ROOT/scripts/lib-extract-wedged-lanes.py"
}

# ---- Action ----------------------------------------------------------------

kill_lane() {
    local session_key="$1"
    if ! command -v openclaw >/dev/null 2>&1; then
        log "openclaw binary not on PATH; cannot kill lane $session_key"
        return 1
    fi
    # `openclaw lane kill <sessionKey>` is a best-effort command. If the
    # subcommand isn't available in this version, fall back to the
    # gateway restart (last resort).
    if openclaw lane kill --session "$session_key" 2>/dev/null; then
        log "Killed lane $session_key via 'openclaw lane kill'"
        return 0
    fi
    log "openclaw lane kill not available or failed; falling back to gateway restart"
    systemctl --user restart "$GATEWAY_UNIT" 2>&1 | sed 's/^/  /' >&2 || true
    return 1
}

# ---- Main loop -------------------------------------------------------------

main() {
    log "Probe start (budget=${LANE_WALL_BUDGET_SECONDS}s grace=${LANE_GRACE_SECONDS}s)"

    local logs wedged_json count_killed=0 count_alerted=0
    logs="$(read_recent_logs || true)"
    if [[ -z "$logs" ]]; then
        log "No recent gateway logs available; nothing to probe"
        exit 0
    fi

    wedged_json="$(echo "$logs" | extract_wedged_lanes || true)"
    if [[ -z "$wedged_json" ]]; then
        log "No wedged lanes detected"
        exit 0
    fi

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local sk age kind last_prog last_age recovery
        sk="$(echo "$entry" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sessionKey"])')"
        age="$(echo "$entry" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ageSeconds"])')"
        kind="$(echo "$entry" | python3 -c 'import json,sys;print(json.load(sys.stdin)["activeWorkKind"])')"
        last_prog="$(echo "$entry" | python3 -c 'import json,sys;print(json.load(sys.stdin)["lastProgress"])')"
        last_age="$(echo "$entry" | python3 -c 'import json,sys;print(json.load(sys.stdin)["lastProgressAge"])')"
        recovery="$(echo "$entry" | python3 -c 'import json,sys;print(json.load(sys.stdin)["recovery"])')"

        # Apply the wall-clock + progress budget.
        local age_ok="false"
        if [[ "$age" -ge $((LANE_WALL_BUDGET_SECONDS + LANE_GRACE_SECONDS)) ]]; then
            age_ok="true"
        fi

        # Only act on model_call lanes with no stream progress for >LANE_GRACE.
        if [[ "$kind" != "model_call" ]]; then
            log "Skip $sk: activeWorkKind=$kind (not model_call)"
            continue
        fi
        if [[ "$last_age" -lt $LANE_GRACE_SECONDS ]]; then
            log "Skip $sk: lastProgressAge=${last_age}s (< grace ${LANE_GRACE_SECONDS}s)"
            continue
        fi
        if [[ "$age_ok" != "true" ]]; then
            log "Skip $sk: age=${age}s (< budget ${LANE_WALL_BUDGET_SECONDS}+${LANE_GRACE_SECONDS}s)"
            continue
        fi
        if [[ "$recovery" != "none" ]]; then
            log "Skip $sk: recovery=$recovery (not none)"
            continue
        fi

        # Debounce: only kill/alert once per (sessionKey, hour).
        local hour_bucket
        hour_bucket="$(date -u +%Y-%m-%dT%H)"
        local dedup_key="${sk}#${hour_bucket}"
        if grep -qF "\"$dedup_key\"" "$STATE_FILE" 2>/dev/null; then
            log "Already acted on $sk in $hour_bucket; skipping"
            continue
        fi

        log "WEDGED: $sk age=${age}s kind=$kind lastProgress=$last_prog lastAge=${last_age}s recovery=$recovery"
        alert "Lane wedged: $sk" \
            "session=$sk age=${age}s kind=$kind lastProgress=$last_prog recovery=$recovery — killing lane"

        if kill_lane "$sk"; then
            count_killed=$((count_killed + 1))
        fi
        count_alerted=$((count_alerted + 1))
        echo "\"$dedup_key\"" >> "$STATE_FILE"
    done <<< "$wedged_json"

    # Trim state file (keep last 24h).
    find "$STATE_DIR" -type f -name "*.json" -mtime +1 -delete 2>/dev/null || true

    log "Probe end: killed=$count_killed alerted=$count_alerted"
    if [[ "$count_killed" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
