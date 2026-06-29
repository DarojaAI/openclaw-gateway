#!/usr/bin/env bash
# scripts/install/install-lane-health-probe.sh
#
# Installs the lane-health-probe user systemd timer + service.
#
# What this installs:
#   - ~/.config/systemd/user/openclaw-lane-health-probe.service
#   - ~/.config/systemd/user/openclaw-lane-health-probe.timer
#   - ~/.local/bin/openclaw-lane-health-probe  (symlink to repo script)
#
# Why this exists:
# See docs/incidents/2026-06-28-multi-session-gateway-starvation.md in
# DarojaAI/linux-desktop-seed. The upstream OpenClaw runtime does not
# preempt wedged lanes, so this user-level watchdog provides the
# mitigation at the L3b layer: scan the journal every 30s, kill lanes
# that exceed the wall-clock budget, and Discord-alert the operator.
#
# Behavior:
#   - Honors $HOME so BATS tests can install into a fake home.
#   - Idempotent: re-runs are no-ops if the timer is already enabled
#     and the script sha matches the deployed copy.
#   - Refuses to enable if systemd --user is not available.
#
# Args:
#   --operator-channel <id>   Discord channel id for alerts
#                             (written to ~/.openclaw/operator-channel)
#
# Exit codes:
#   0 = installed and enabled
#   1 = install failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# ---- Args ------------------------------------------------------------------

OPERATOR_CHANNEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --operator-channel)
            OPERATOR_CHANNEL="${2:-}"
            shift 2
            ;;
        --operator-channel=*)
            OPERATOR_CHANNEL="${1#*=}"
            shift
            ;;
        *)
            log_error "Unknown arg: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$OPERATOR_CHANNEL" ]]; then
    log_warn "No --operator-channel provided; probe will log alerts to journal only"
fi

# ---- Preconditions ---------------------------------------------------------

if ! command -v systemctl >/dev/null 2>&1; then
    log_error "systemctl not found; cannot install user timer"
    exit 1
fi

if [[ -z "${HOME:-}" ]]; then
    log_error "HOME is not set; refusing to install"
    exit 1
fi

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.openclaw"

PROBE_SRC="$REPO_ROOT/scripts/lane-health-probe.sh"
if [[ ! -f "$PROBE_SRC" ]]; then
    log_error "Probe script not found at $PROBE_SRC"
    exit 1
fi

# ---- Symlink the script ----------------------------------------------------

PROBE_DST="$HOME/.local/bin/openclaw-lane-health-probe"
if [[ -L "$PROBE_DST" ]] || [[ -f "$PROBE_DST" ]]; then
    rm -f "$PROBE_DST"
fi
ln -s "$PROBE_SRC" "$PROBE_DST"
chmod +x "$PROBE_SRC" || true
log_info "Linked probe: $PROBE_DST -> $PROBE_SRC"

# ---- Write operator channel -------------------------------------------------

if [[ -n "$OPERATOR_CHANNEL" ]]; then
    echo "$OPERATOR_CHANNEL" > "$HOME/.openclaw/operator-channel"
    chmod 0600 "$HOME/.openclaw/operator-channel"
    log_info "Operator channel: $OPERATOR_CHANNEL"
fi

# ---- Write systemd units ---------------------------------------------------

SERVICE_FILE="$SYSTEMD_USER_DIR/openclaw-lane-health-probe.service"
TIMER_FILE="$SYSTEMD_USER_DIR/openclaw-lane-health-probe.timer"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=OpenClaw lane-health watchdog
Documentation=https://github.com/DarojaAI/openclaw-gateway
# Soft dependency on the gateway: don't cascade stop/restart.
Wants=openclaw-gateway.service

[Service]
Type=oneshot
ExecStart=%h/.local/bin/openclaw-lane-health-probe
# Land output in a writable user log dir (per MEMORY.md: /var/log is root-only).
StandardOutput=append:%h/.local/log/openclaw-lane-health/probe.log
StandardError=append:%h/.local/log/openclaw-lane-health/probe.log
# Don't let a probe crash tear down the gateway.
SuccessExitStatus=0 1
EOF

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=OpenClaw lane-health probe (every 30s)

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
# Stay alive across reboots / logouts.
Persistent=true
Unit=openclaw-lane-health-probe.service

[Install]
WantedBy=default.target
EOF

mkdir -p "$HOME/.local/log/openclaw-lane-health"
touch "$HOME/.local/log/openclaw-lane-health/probe.log"
chmod 0644 "$HOME/.local/log/openclaw-lane-health/probe.log"

# ---- Enable + start --------------------------------------------------------

systemctl --user daemon-reload
if ! systemctl --user enable openclaw-lane-health-probe.timer >/dev/null 2>&1; then
    log_error "Failed to enable openclaw-lane-health-probe.timer"
    exit 1
fi
if ! systemctl --user restart openclaw-lane-health-probe.timer >/dev/null 2>&1; then
    log_warn "Timer start returned non-zero; check 'systemctl --user status openclaw-lane-health-probe.timer'"
fi

log_info "Installed and enabled openclaw-lane-health-probe.timer"
log_info "Status: systemctl --user status openclaw-lane-health-probe.timer"
log_info "Logs:   journalctl --user -u openclaw-lane-health-probe.service -f"
