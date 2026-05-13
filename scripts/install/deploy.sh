#!/bin/bash
# OpenClaw Gateway Self-Install
# Called by linux-desktop-seed deploy after cloning this repo to /tmp/openclaw-gateway
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

log_info "Installing OpenClaw Gateway from $REPO_ROOT"

# 1. Install OpenClaw binary (if not already installed)
if command -v openclaw &>/dev/null; then
    log_info "OpenClaw already installed: $(openclaw --version)"
else
    log_info "Installing OpenClaw..."
    bash "$SCRIPT_DIR/install.sh"
fi

# 2. Install model manager globally
model_manager_src="$REPO_ROOT/scripts/openclaw-model-manager.py"
model_manager_dst="/usr/local/bin/openclaw-model-manager"
if [[ -f "$model_manager_src" ]]; then
    cp "$model_manager_src" "$model_manager_dst"
    chmod +x "$model_manager_dst"
    log_info "Installed openclaw-model-manager to $model_manager_dst"
else
    log_warn "openclaw-model-manager.py not found"
fi

# 3. Deploy OpenClaw config (skills, defaults, workspace)
# This uses the existing config.sh which expects repo_root as first arg
bash "$SCRIPT_DIR/config.sh" "$REPO_ROOT"

# 4. Install cost monitor companion script
cost_monitor_src="$REPO_ROOT/scripts/cost-monitor.py"
cost_monitor_dst="/usr/local/bin/openclaw-cost-monitor"
if [[ -f "$cost_monitor_src" ]]; then
    cp "$cost_monitor_src" "$cost_monitor_dst"
    chmod +x "$cost_monitor_dst"
    log_info "Installed cost-monitor to $cost_monitor_dst"
fi

log_info "OpenClaw Gateway installation complete"
