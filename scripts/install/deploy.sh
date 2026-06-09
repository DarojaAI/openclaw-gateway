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
    log_info "OpenClaw binary already installed"
else
    OPENCLAW_BIN="$REPO_ROOT/openclaw"
    if [[ -f "$OPENCLAW_BIN" ]]; then
        log_info "Installing OpenClaw binary..."
        chmod +x "$OPENCLAW_BIN"
        cp "$OPENCLAW_BIN" /usr/local/bin/openclaw
        log_info "OpenClaw binary installed"
    else
        log_warn "OpenClaw binary not found at $OPENCLAW_BIN"
    fi
fi

# 2. Install model manager globally
model_manager_src="$REPO_ROOT/scripts/openclaw-model-manager.py"
model_manager_dst="/usr/local/bin/openclaw-model-manager"
if [[ -f "$model_manager_src" ]]; then
    log_info "Installing OpenClaw model manager..."
    chmod +x "$model_manager_src"
    cp "$model_manager_src" "$model_manager_dst"
    log_info "Model manager installed to $model_manager_dst"
else
    log_warn "Model manager not found at $model_manager_src"
fi

# 3. Config is written by L3 (linux-desktop-seed) deploy pipeline
# L3b (this repo) owns canonical defaults in config/openclaw-defaults.json
# L3 writes the full config via merge-openclaw-config.py during deploy
# L2 (linux-desktop-setup) handles VM installation, not configuration

# 4. Install cost monitor companion script
cost_monitor_src="$REPO_ROOT/scripts/cost-monitor.py"
cost_monitor_dst="/usr/local/bin/openclaw-cost-monitor"
if [[ -f "$cost_monitor_src" ]]; then
    log_info "Installing OpenClaw cost monitor..."
    chmod +x "$cost_monitor_src"
    cp "$cost_monitor_src" "$cost_monitor_dst"
    log_info "Cost monitor installed to $cost_monitor_dst"
else
    log_warn "Cost monitor not found at $cost_monitor_src"
fi

# 5. Install shared viz service (mermaid/graphviz/chartjs render server)
viz_install_src="$REPO_ROOT/scripts/services/install-viz-service.sh"
if [[ -f "$viz_install_src" ]]; then
    log_info "Installing shared viz service..."
    bash "$viz_install_src"
else
    log_warn "Viz service installer not found at $viz_install_src"
fi

log_info "OpenClaw Gateway installation complete"
