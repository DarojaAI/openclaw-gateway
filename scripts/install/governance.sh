#!/bin/bash
# OpenCLAW config governance: lock, validate, backup, change-request scripts
# Writes governance tools to /usr/local/bin/ on the target VM
# Source this from ai-tools.sh

set -euo pipefail

# Resolve lib.sh from scripts/lib/ (sibling to scripts/install/)
_lib_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd -P)/scripts/deploy"
# shellcheck source=../deploy/lib.sh
source "${_lib_sh_dir}/lib.sh"

setup_openclaw_lock_config() {
    log_step "Setting up OpenCLAW config lock script..."

    local lock_script="/usr/local/bin/openclaw-lock-config.sh"

    cat > "$lock_script" << 'EOF'
#!/bin/bash
# Locks or unlocks the OpenCLAW config file

set -euo pipefail

CONFIG_FILE="/home/desktopuser/.openclaw/openclaw.json"
ROOT_CONFIG_FILE="/root/.openclaw/openclaw.json"

show_usage() {
    echo "Usage: $0 [lock|unlock|status]"
    exit 1
}

get_perms() { stat -c "%a" "$CONFIG_FILE" 2>/dev/null || echo "none"; }

do_status() {
    local perms; perms=$(get_perms)
    echo "Config: $CONFIG_FILE  Permissions: $perms"
    case "$perms" in
        444) echo "Status: LOCKED (read-only)" ;;
        644) echo "Status: UNLOCKED (writable)" ;;
        *)   echo "Status: UNKNOWN" ;;
    esac
}

do_lock() {
    chmod 444 "$CONFIG_FILE" && chown desktopuser:desktopuser "$CONFIG_FILE"
    chmod 444 "$ROOT_CONFIG_FILE" && chown root:root "$ROOT_CONFIG_FILE"
    echo "Config locked"; do_status

    # Store checksum after locking
    _checksum_script="/usr/local/bin/openclaw-checksum.sh"
    if [[ -f "$_checksum_script" ]]; then
        source "$_checksum_script"
        store_config_checksum
    fi
}

do_unlock() {
    # Verify checksum before unlocking to detect drift
    _checksum_script="/usr/local/bin/openclaw-checksum.sh"
    if [[ -f "$_checksum_script" ]]; then
        source "$_checksum_script"
        if ! verify_config_checksum; then
            echo "ERROR: Config checksum verification failed — refusing to unlock"
            echo "  Run: $0 validate-and-lock to force re-lock, or check backups"
            exit 1
        fi
    fi

    chmod 644 "$CONFIG_FILE" && chown desktopuser:desktopuser "$CONFIG_FILE"
    chmod 644 "$ROOT_CONFIG_FILE" && chown root:root "$ROOT_CONFIG_FILE"
    echo "Config unlocked"; do_status
}

case "${1:-status}" in
    lock) do_lock ;; unlock) do_unlock ;; status) do_status ;; *) show_usage ;;
esac
EOF

    chmod +x "$lock_script"
    log_info "OpenCLAW lock config script created at $lock_script"
}

setup_openclaw_validate_config() {
    log_step "Setting up OpenCLAW config validation script..."

    local validate_script="/usr/local/bin/openclaw-validate-config.sh"

    cat > "$validate_script" << 'EOF'
#!/bin/bash
# Validates OpenCLAW config before any change or restart

set -euo pipefail

CONFIG_FILE="${1:-/home/desktopuser/.openclaw/openclaw.json}"
ERRORS=0

echo "=== OpenCLAW Config Validation ===" && echo "Config: $CONFIG_FILE" && echo ""

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: Config file not found"; exit 1; }

echo "[1/7] Checking JSON validity..."
jq -e '.' "$CONFIG_FILE" >/dev/null 2>&1 && echo "  OK: Valid JSON" || { echo "ERROR: Invalid JSON"; ERRORS=$((ERRORS+1)); }

echo "[2/7] Checking required sections..."
for section in meta models channels bindings; do
    jq -e ".$section" "$CONFIG_FILE" >/dev/null 2>&1 \
        && echo "  OK: '$section' exists" \
        || { echo "ERROR: Missing section: $section"; ERRORS=$((ERRORS+1)); }
done

echo "[3/7] Checking provider configuration..."
jq -e '.models.providers.openrouter | has("baseUrl")' "$CONFIG_FILE" >/dev/null 2>&1 \
    && echo "  OK: baseUrl present" \
    || { echo "ERROR: Missing baseUrl"; ERRORS=$((ERRORS+1)); }

jq -e '.models.providers.openrouter | has("models")' "$CONFIG_FILE" >/dev/null 2>&1 \
    && echo "  OK: models array present ($(jq '.models.providers.openrouter.models | length' "$CONFIG_FILE") models)" \
    || { echo "ERROR: Missing models array"; ERRORS=$((ERRORS+1)); }

echo "[4/7] Checking bindings..."
echo "  Found $(jq '.bindings | length' "$CONFIG_FILE" 2>/dev/null || echo 0) bindings"

echo "[5/7] Checking Discord configuration..."
jq -e '.channels.discord.enabled == true' "$CONFIG_FILE" >/dev/null 2>&1 \
    && echo "  OK: Discord enabled" || echo "WARNING: Discord not enabled"

DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' "$CONFIG_FILE")
[[ -n "$DISCORD_TOKEN" && "$DISCORD_TOKEN" != "DISCORD_BOT_TOKEN_PLACEHOLDER" ]] \
    && echo "  OK: Discord token present" || echo "WARNING: Discord token missing or placeholder"

echo "[6/7] Checking gateway configuration..."
jq -e '.gateway.mode' "$CONFIG_FILE" >/dev/null 2>&1 \
    && echo "  OK: Gateway mode: $(jq -r '.gateway.mode' "$CONFIG_FILE")" \
    || { echo "ERROR: Missing gateway.mode"; ERRORS=$((ERRORS+1)); }

echo "[7/7] Summary"
[[ $ERRORS -gt 0 ]] && { echo "RESULT: FAILED with $ERRORS error(s)"; exit 1; } || echo "RESULT: PASSED"
EOF

    chmod +x "$validate_script"
    log_info "OpenCLAW config validation script created at $validate_script"
}

setup_openclaw_backup_config() {
    log_step "Setting up OpenCLAW config backup script..."

    local backup_script="/usr/local/bin/openclaw-backup-config.sh"

    cat > "$backup_script" << 'EOF'
#!/bin/bash
# Creates timestamped backups of OpenCLAW config

set -euo pipefail

CONFIG_DIR="/home/desktopuser/.openclaw"
ROOT_CONFIG_DIR="/root/.openclaw"
TIMESTAMP=$(date +%Y-%m-%dT%H-%M-%S)

echo "=== OpenCLAW Config Backup === Timestamp: $TIMESTAMP"

[[ -f "$CONFIG_DIR/openclaw.json" ]] && \
    cp "$CONFIG_DIR/openclaw.json" "$CONFIG_DIR/openclaw-backup.$TIMESTAMP.json"

[[ -f "$ROOT_CONFIG_DIR/openclaw.json" ]] && \
    cp "$ROOT_CONFIG_DIR/openclaw.json" "$CONFIG_DIR/openclaw-root-backup.$TIMESTAMP.json"

# Keep last 10 backups
cd "$CONFIG_DIR"
ls -1 openclaw-backup.*.json 2>/dev/null | tail -n +11 | xargs -r rm
ls -1 openclaw-root-backup.*.json 2>/dev/null | tail -n +11 | xargs -r rm

echo "Backup complete"
EOF

    chmod +x "$backup_script"
    log_info "OpenCLAW config backup script created at $backup_script"
}

setup_openclaw_change_request() {
    log_step "Setting up OpenCLAW change request governance script..."

    local change_request_script="/usr/local/bin/openclaw-change-request.sh"

    cat > "$change_request_script" << 'EOF'
#!/bin/bash
# Enforces governance process for OpenCLAW config changes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="/home/desktopuser/.openclaw/openclaw.json"
ROOT_CONFIG_FILE="/root/.openclaw/openclaw.json"
CONFIG_DIR="/home/desktopuser/.openclaw"
LOCK_SCRIPT="$SCRIPT_DIR/openclaw-lock-config.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/openclaw-validate-config.sh"
BACKUP_SCRIPT="$SCRIPT_DIR/openclaw-backup-config.sh"
CHECKSUM_SCRIPT="$SCRIPT_DIR/openclaw-checksum.sh"

show_usage() {
    cat <<USAGE
OpenCLAW Configuration Change Request
Usage: $0 [request|approve|apply|status]
  request <description>  - Create a change request
  approve <request_id>   - Approve a pending change
  apply <request_id>     - Apply an approved change
  status                 - Show pending requests
USAGE
    exit 1
}

do_request() {
    local description="$*"
    local request_id="cr-$(date +%Y%m%d-%H%M%S)"
    [[ -n "$description" ]] || { echo "ERROR: Description required"; exit 1; }

    mkdir -p "$CONFIG_DIR/requests"
    cat > "$CONFIG_DIR/requests/$request_id.json" << REQEOF
{
  "request_id": "$request_id",
  "description": "$description",
  "requested_by": "$(whoami)",
  "timestamp": "$(date -Iseconds)",
  "status": "pending"
}
REQEOF
    echo "Change request $request_id created. Milan must approve before applying."
}

do_approve() {
    local request_id="${1:?Request ID required}"
    local request_file="$CONFIG_DIR/requests/$request_id.json"
    [[ -f "$request_file" ]] || { echo "ERROR: Request not found: $request_id"; exit 1; }

    local approver; approver="$(whoami)"
    [[ "$approver" == "root" || "$approver" == "desktopuser" ]] || { echo "ERROR: Only Milan can approve"; exit 1; }

    jq ".status = \"approved\" | .approved_by = \"$approver\" | .approval_timestamp = \"$(date -Iseconds)\"" \
        "$request_file" > "$request_file.tmp" && mv "$request_file.tmp" "$request_file"
    echo "Approved: $request_id by $approver"
}

do_apply() {
    local request_id="${1:?Request ID required}"
    local request_file="$CONFIG_DIR/requests/$request_id.json"
    [[ -f "$request_file" ]] || { echo "ERROR: Request not found"; exit 1; }

    local status; status=$(jq -r '.status' "$request_file")
    [[ "$status" == "approved" ]] || { echo "ERROR: Request not approved (status: $status)"; exit 1; }

    echo "=== Applying: $request_id ==="
    echo "[1/4] Backup...";  $BACKUP_SCRIPT
    echo "[2/4] Unlock...";  $LOCK_SCRIPT unlock
    echo "[3/4] Validate..."; $VALIDATE_SCRIPT || { $LOCK_SCRIPT lock; exit 1; }
    echo "[4/4] Config unlocked. Edit $CONFIG_FILE then run: $0 validate-and-lock"
}

do_validate_and_lock() {
    $VALIDATE_SCRIPT || { echo "ERROR: Validation failed. Rollback manually."; exit 1; }
    cp "$CONFIG_FILE" "$ROOT_CONFIG_FILE"
    $LOCK_SCRIPT lock

    # Verify checksum after locking
    if [[ -f "$CHECKSUM_SCRIPT" ]]; then
        source "$CHECKSUM_SCRIPT"
        verify_config_checksum
    fi

    echo "SUCCESS: Change applied and config locked"
}

do_status() {
    $LOCK_SCRIPT status
    echo ""
    echo "Pending requests:"
    for req in "$CONFIG_DIR/requests/"*.json 2>/dev/null; do
        [[ -f "$req" ]] || continue
        echo "  $(jq -r '"\(.request_id): \(.status) - \(.description)"' "$req")"
    done
}

case "${1:-status}" in
    request) shift; do_request "$@" ;;
    approve) shift; do_approve "$@" ;;
    apply)   shift; do_apply "$@" ;;
    validate-and-lock) do_validate_and_lock ;;
    status) do_status ;;
    *) show_usage ;;
esac
EOF

    chmod +x "$change_request_script"
    log_info "OpenCLAW change request governance script created at $change_request_script"
}

setup_openclaw_checksum() {
    log_step "Setting up OpenCLAW config checksum and drift detection script..."

    local checksum_script="/usr/local/bin/openclaw-checksum.sh"

    cat > "$checksum_script" << 'EOF'
#!/bin/bash
# OpenClaw config checksum and drift detection
# Source this script for checksum functions

set -euo pipefail

TARGET_USER="${TARGET_USER:-desktopuser}"
CONFIG_FILE="/home/$TARGET_USER/.openclaw/openclaw.json"
CHECKSUM_FILE="/home/$TARGET_USER/.openclaw/.config.checksum"
BACKUP_DIR="/home/$TARGET_USER/.openclaw"

store_config_checksum() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Config file not found: $CONFIG_FILE"
        return 1
    fi

    local checksum
    checksum=$(md5sum "$CONFIG_FILE" | cut -d' ' -f1)
    echo "$checksum" > "$CHECKSUM_FILE"
    chown "$TARGET_USER:$TARGET_USER" "$CHECKSUM_FILE"

    echo "Config checksum stored: $checksum"
    return 0
}

verify_config_checksum() {
    if [[ ! -f "$CHECKSUM_FILE" ]]; then
        echo "WARNING: No checksum file found - storing initial checksum"
        store_config_checksum
        return 0
    fi

    local stored_checksum
    stored_checksum=$(cat "$CHECKSUM_FILE")
    local current_checksum
    current_checksum=$(md5sum "$CONFIG_FILE" | cut -d' ' -f1)

    if [[ "$stored_checksum" != "$current_checksum" ]]; then
        echo "ERROR: Config drift detected!"
        echo "  Stored: $stored_checksum"
        echo "  Current: $current_checksum"
        return 1
    fi

    echo "Config checksum verified: OK"
    return 0
}

auto_restore_config() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo "ERROR: No backups directory found: $BACKUP_DIR"
        return 1
    fi

    local latest_backup
    latest_backup=$(ls -t "$BACKUP_DIR"/openclaw-backup.*.json 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        echo "ERROR: No backups found in $BACKUP_DIR"
        return 1
    fi

    echo "Restoring config from: $latest_backup"

    # Unlock config if locked
    if [[ -f "$CONFIG_FILE.lock" ]]; then
        rm -f "$CONFIG_FILE.lock"
    fi

    cp "$latest_backup" "$CONFIG_FILE"
    chown "$TARGET_USER:$TARGET_USER" "$CONFIG_FILE"
    chmod 444 "$CONFIG_FILE"

    # Store new checksum
    store_config_checksum

    echo "Config auto-restored from backup"
    return 0
}
EOF

    chmod +x "$checksum_script"
    log_info "OpenCLAW config checksum script created at $checksum_script"
}

export -f setup_openclaw_lock_config setup_openclaw_validate_config setup_openclaw_backup_config setup_openclaw_change_request setup_openclaw_checksum
