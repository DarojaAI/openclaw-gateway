#!/bin/bash
# OpenCLAW installation: install, wrapper setup, npm cleanup
# Source this from ai-tools.sh

set -euo pipefail

# Resolve lib.sh from scripts/lib/ (sibling to scripts/install/)
_lib_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd -P)/scripts/deploy"
# shellcheck source=../deploy/lib.sh
source "${_lib_sh_dir}/lib.sh"

# Source health check functions
# shellcheck source=health.sh
source "$(dirname "${BASH_SOURCE[0]}")/health.sh"

cleanup_openclaw_npm() {
    log_info "Cleaning up old OpenCLAW npm artifacts..."

    local npm_global_path
    npm_global_path=$(npm root -g 2>/dev/null || echo "/usr/lib/node_modules")

    if [[ -d "$npm_global_path/openclaw" ]]; then
        rm -rf "$npm_global_path/openclaw"
        log_info "Removed old OpenCLAW npm package"
    fi

    rm -f /usr/bin/openclaw 2>/dev/null || true
    rm -f /usr/local/bin/openclaw 2>/dev/null || true
    npm cache clean --force 2>/dev/null || true

    log_info "NPM cleanup complete"
}

get_latest_openclaw_version() {
    npm show openclaw version 2>/dev/null || echo ""
}

install_openclaw() {
    log_step "Installing OpenCLAW..."

    local OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.5.7}"

    if command -v openclaw &> /dev/null; then
        local oc_version
        oc_version=$(openclaw --version 2>/dev/null || echo "installed")
        # Extract version number from output like "OpenClaw 2026.4.26 (be8c246)" -> "2026.4.26"
        local installed_version
        installed_version=$(echo "$oc_version" | sed -E 's/.*OpenClaw[ _]?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
        if [[ "$installed_version" == "$OPENCLAW_VERSION" ]]; then
            log_info "OpenCLAW already installed: $oc_version"
            return 0
        else
            log_warn "OpenCLAW version mismatch: $installed_version != $OPENCLAW_VERSION, reinstalling..."
            cleanup_openclaw_npm
        fi
    fi

    if ! command -v node &> /dev/null || [[ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 22 ]]; then
        log_info "Installing Node.js 22.x for OpenCLAW..."
        if ! curl -fsSL https://deb.nodesource.com/setup_22.x | bash -; then
            log_error "Failed to setup NodeSource repository"
            return 1
        fi
        if ! apt-get install -y nodejs; then
            log_error "Failed to install Node.js"
            return 1
        fi
        cleanup_openclaw_npm
        log_info "Node.js 22.x installed"
    fi

    if command -v npm &> /dev/null; then
        if npm install -g "openclaw@$OPENCLAW_VERSION" 2>&1; then
            if command -v openclaw &> /dev/null; then
                log_info "OpenCLAW installed successfully"
            else
                local npm_global_path
                npm_global_path=$(npm root -g 2>/dev/null)
                if [ -f "$npm_global_path/openclaw/bin/openclaw.js" ]; then
                    ln -sf "$npm_global_path/openclaw/bin/openclaw.js" /usr/bin/openclaw 2>/dev/null || true
                fi
                if command -v openclaw &> /dev/null; then
                    log_info "OpenCLAW installed successfully"
                else
                    log_warn "OpenCLAW npm package installed but command not found"
                fi
            fi
        else
            log_warn "Failed to install OpenCLAW via npm"
        fi
    else
        log_warn "npm not available - cannot install OpenCLAW"
    fi
}

setup_openclaw_wrapper() {
    log_step "Setting up OpenCLAW wrapper..."

    local wrapper_path="/usr/local/bin/openclaw-wrapper"
    cat > "$wrapper_path" << 'EOF'
#!/bin/bash
# OpenCLAW wrapper - ensures environment variables are set

if [[ -f "$HOME/.bashrc" ]]; then
    source "$HOME/.bashrc" 2>/dev/null || true
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "Error: OPENROUTER_API_KEY not set"
    exit 1
fi

exec openclaw "$@"
EOF

    chmod +x "$wrapper_path"
    log_info "OpenCLAW wrapper created at $wrapper_path"
}

setup_openclaw_systemd_service() {
    log_step "Setting up OpenCLAW gateway systemd service..."

    local target_home
    target_home=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    local service_dir="$target_home/.config/systemd/user"
    local service_file="$service_dir/openclaw-gateway.service"
    local override_dir="$service_dir/openclaw-gateway.service.d"
    local override_file="$override_dir/override.conf"

    local openclaw_path
    openclaw_path=$(command -v openclaw 2>/dev/null || echo "/usr/bin/openclaw")

    # Get Node.js path
    local node_path
    node_path=$(command -v node 2>/dev/null || echo "/usr/bin/node")

    # Create service directory
    mkdir -p "$service_dir"

    # Create systemd service file
    cat > "$service_file" << EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
ExecStart=$node_path $openclaw_path gateway --port 18789
Restart=always
RestartSec=5
RestartPreventExitStatus=78
TimeoutStopSec=30
TimeoutStartSec=30
SuccessExitStatus=0 143
KillMode=control-group

[Install]
WantedBy=default.target
EOF

    # Create override directory
    mkdir -p "$override_dir"

    # Get user ID for XDG_RUNTIME_DIR
    local user_id
    user_id=$(id -u "$TARGET_USER")

    # Build environment override - API key must come from environment variable
    local api_key="${OPENROUTER_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
        log_error "OPENROUTER_API_KEY environment variable is required"
        return 1
    fi
    local discord_token="${DISCORD_BOT_TOKEN:-}"

    cat > "$override_file" << EOF
[Service]
Environment=OPENROUTER_API_KEY=$api_key
Environment=HOME=$target_home
Environment=XDG_RUNTIME_DIR=/run/user/$user_id
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$target_home/.local/bin:$target_home/.npm-global/bin
EOF

    # Add Discord token if available
    if [[ -n "$discord_token" ]]; then
        echo "Environment=DISCORD_BOT_TOKEN=$discord_token" >> "$override_file"
    fi

    # Set ownership
    chown -R "$TARGET_USER:$TARGET_USER" "$service_dir"

    # Enable linger for the user - allows systemd user services to run without active session
    # This is required because the deployment runs via SSH, not an interactive session
    log_info "Enabling linger for user $TARGET_USER..."
    if ! loginctl enable-linger "$TARGET_USER" 2>/dev/null; then
        log_warn "Could not enable linger (may already be enabled or requires systemd-logind)"
    fi

    # Reload systemd user daemon to recognize the new service file
    log_info "Reloading systemd user daemon..."
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$user_id" systemctl --user daemon-reload

    # Enable and start the systemd service
    log_info "Enabling openclaw-gateway.service..."
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$user_id" systemctl --user enable openclaw-gateway.service

    log_info "Starting openclaw-gateway.service..."
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$user_id" systemctl --user start openclaw-gateway.service

    # Verify service started successfully
    sleep 2
    if sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$user_id" systemctl --user is-active openclaw-gateway.service 2>/dev/null; then
        log_info "OpenCLAW gateway started successfully via systemd"
    else
        log_warn "OpenCLAW gateway may not have started, check systemctl --user status openclaw-gateway.service"
    fi

    log_info "OpenCLAW systemd service created at $service_file"
}

export -f cleanup_openclaw_npm get_latest_openclaw_version \
    install_openclaw setup_openclaw_wrapper \
    setup_openclaw_systemd_service \
    check_process check_endpoint check_discord main
