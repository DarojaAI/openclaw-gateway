#!/usr/bin/env bats
#
# health-monitoring.bats — Tests for heartbeat health monitoring (RFC #31 Phase 6, Issue #49).
#
# Covers:
#   - Agent health status check (healthy, quarantined, no-heartbeat)
#   - Quarantine state management (quarantine/unquarantine)
#   - Quarantine integration with capability-dispatch.py
#   - Quarantine integration with route-by-handle.py
#   - Missing lockfile
#   - JSON output shape
#

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HEALTH_SCRIPT="${REPO_ROOT}/scripts/health-monitoring.py"
QUARANTINE_SCRIPT="${REPO_ROOT}/scripts/quarantine.py"
LOCKFILE="${REPO_ROOT}/config/agents.lock.toml"
DISPATCH_SCRIPT="${REPO_ROOT}/scripts/capability-dispatch.py"
ROUTE_SCRIPT="${REPO_ROOT}/scripts/route-by-handle.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run the health monitoring script with arguments.
run_health() {
    run python3 "${HEALTH_SCRIPT}" --lockfile "${LOCKFILE}" "$@"
}

# Run with custom lockfile
run_health_lockfile() {
    local lockfile="$1"
    shift
    run python3 "${HEALTH_SCRIPT}" --lockfile "${lockfile}" "$@"
}

# Run the quarantine script with arguments.
run_quarantine() {
    run python3 "${QUARANTINE_SCRIPT}" --lockfile "${LOCKFILE}" "$@"
}

# Run with custom lockfile
run_quarantine_lockfile() {
    local lockfile="$1"
    shift
    run python3 "${QUARANTINE_SCRIPT}" --lockfile "${lockfile}" "$@"
}

# Create a temporary lockfile for testing
setup_tmp_lockfile() {
    TMP_LOCKFILE_DIR="$(mktemp -d)"
    TMP_LOCKFILE="${TMP_LOCKFILE_DIR}/agents.lock.toml"
    cat > "${TMP_LOCKFILE}" << 'EOF'
schema_version = "1"

[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@linux-desktop-seed"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
capabilities     = ["vm-provision", "vm-decommission", "pr-stewardship"]
role             = "executor"
allowed_channels = ["1501612164098687087"]
heartbeat_enabled = true
heartbeat_interval_hours = 24
canary           = false

[agents.darojaai_architect]
repo             = "DarojaAI/darojaai_architect"
handle           = "@darojaai-architect"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/darojaai_architect/blob/main/.openclaw/agent-config.yaml"
config_sha       = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"
capabilities     = ["architecture", "code-review", "design-patterns"]
role             = "advisor"
allowed_channels = ["1501612164098687087"]
heartbeat_enabled = true
heartbeat_interval_hours = 24
canary           = false

[agents.mcp-tooling]
repo             = "DarojaAI/mcp-tooling"
handle           = "@mcp-tooling"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/mcp-tooling/blob/main/.openclaw/agent-config.yaml"
config_sha       = "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
capabilities     = ["mcp-server", "tool-management"]
role             = "executor"
allowed_channels = ["1501612164098687087"]
heartbeat_enabled = true
heartbeat_interval_hours = 24
canary           = false

[agents.openclaw-gateway]
repo             = "DarojaAI/openclaw-gateway"
handle           = "@openclaw-gateway"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/openclaw-gateway/blob/main/.openclaw/agent-config.yaml"
config_sha       = "f0e1d2c3b4a5f0e1d2c3b4a5f0e1d2c3b4a5f0e1"
capabilities     = ["gateway", "orchestration"]
role             = "executor"
allowed_channels = ["1501612164098687087"]
heartbeat_enabled = true
heartbeat_interval_hours = 24
canary           = false
EOF
}

# Create a temporary lockfile without heartbeat
setup_tmp_lockfile_no_heartbeat() {
    TMP_LOCKFILE_DIR="$(mktemp -d)"
    TMP_LOCKFILE="${TMP_LOCKFILE_DIR}/agents.lock.toml"
    cat > "${TMP_LOCKFILE}" << 'EOF'
schema_version = "1"

[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@linux-desktop-seed"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
capabilities     = ["vm-provision", "vm-decommission", "pr-stewardship"]
role             = "executor"
allowed_channels = ["1501612164098687087"]
heartbeat_enabled = false
heartbeat_interval_hours = 0
canary           = false
EOF
}

# Clean up temp files
cleanup_tmp() {
    if [[ -n "${TMP_LOCKFILE_DIR:-}" && -d "${TMP_LOCKFILE_DIR}" ]]; then
        rm -rf "${TMP_LOCKFILE_DIR}"
    fi
    # Clean up quarantine store
    rm -f "${REPO_ROOT}/config/quarantine.json"
}

# ---------------------------------------------------------------------------
# Tests — Health monitoring status
# ---------------------------------------------------------------------------

@test "1. check all agents health — all healthy" {
    setup_tmp_lockfile
    run_health_lockfile "${TMP_LOCKFILE}" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *'"total": 4'* ]]
    [[ "$output" == *'"healthy": 4'* ]]
    [[ "$output" == *'"quarantined": 0'* ]]
    cleanup_tmp
}

@test "2. check specific agent health — healthy" {
    setup_tmp_lockfile
    run_health_lockfile "${TMP_LOCKFILE}" --agent linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "healthy"'* ]]
    [[ "$output" == *'"slug": "linux-desktop-seed"'* ]]
    cleanup_tmp
}

@test "3. check agent without heartbeat — no-heartbeat" {
    setup_tmp_lockfile_no_heartbeat
    run_health_lockfile "${TMP_LOCKFILE}" --agent linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "no-heartbeat"'* ]]
    cleanup_tmp
}

# ---------------------------------------------------------------------------
# Tests — Quarantine state management
# ---------------------------------------------------------------------------

@test "4. quarantine agent" {
    setup_tmp_lockfile
    run_quarantine_lockfile "${TMP_LOCKFILE}" --quarantine linux-desktop-seed --reason "heartbeat missed"
    [ "$status" -eq 0 ]
    [[ "$output" == *"quarantined"* ]]
    cleanup_tmp
}

@test "5. unquarantine agent" {
    setup_tmp_lockfile
    run_quarantine_lockfile "${TMP_LOCKFILE}" --quarantine linux-desktop-seed --reason "test"
    [ "$status" -eq 0 ]
    run_quarantine_lockfile "${TMP_LOCKFILE}" --unquarantine linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"unquarantine"* ]]
    cleanup_tmp
}

@test "6. list quarantined agents" {
    setup_tmp_lockfile
    run_quarantine_lockfile "${TMP_LOCKFILE}" --quarantine linux-desktop-seed --reason "test"
    run_quarantine_lockfile "${TMP_LOCKFILE}" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
    cleanup_tmp
}

@test "7. is-quarantined check — quarantined" {
    setup_tmp_lockfile
    run_quarantine_lockfile "${TMP_LOCKFILE}" --quarantine linux-desktop-seed --reason "test"
    run_quarantine_lockfile "${TMP_LOCKFILE}" --is-quarantined linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"quarantined"* ]]
    cleanup_tmp
}

@test "8. is-quarantined check — not quarantined" {
    setup_tmp_lockfile
    run_quarantine_lockfile "${TMP_LOCKFILE}" --is-quarantined linux-desktop-seed
    [ "$status" -eq 1 ]
    [[ "$output" == *"not quarantined"* ]]
    cleanup_tmp
}

# ---------------------------------------------------------------------------
# Tests — Quarantine integration with capability-dispatch.py
# ---------------------------------------------------------------------------

@test "9. capability-dispatch rejects quarantined agent" {
    setup_tmp_lockfile
    run_quarantine_lockfile "${TMP_LOCKFILE}" --quarantine linux-desktop-seed --reason "heartbeat missed"
    run python3 "${DISPATCH_SCRIPT}" --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$status" -eq 1 ]
    [[ "$output" == *"quarantined"* ]]
    cleanup_tmp
}

@test "10. capability-dispatch routes non-quarantined agent" {
    setup_tmp_lockfile
    run python3 "${DISPATCH_SCRIPT}" --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
    [[ "$output" == *'"match_type": "handle"'* ]]
    cleanup_tmp
}

# ---------------------------------------------------------------------------
# Tests — Quarantine integration with route-by-handle.py
# ---------------------------------------------------------------------------

@test "11. route-by-handle rejects quarantined agent" {
    setup_tmp_lockfile
    run_quarantine_lockfile "${TMP_LOCKFILE}" --quarantine linux-desktop-seed --reason "heartbeat missed"
    run python3 "${ROUTE_SCRIPT}" --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$status" -eq 1 ]
    [[ "$output" == *"quarantined"* ]]
    cleanup_tmp
}

@test "12. route-by-handle routes non-quarantined agent" {
    setup_tmp_lockfile
    run python3 "${ROUTE_SCRIPT}" --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
    cleanup_tmp
}

# ---------------------------------------------------------------------------
# Tests — JSON output shape
# ---------------------------------------------------------------------------

@test "13. health check output is valid JSON" {
    setup_tmp_lockfile
    run_health_lockfile "${TMP_LOCKFILE}" --check
    [ "$status" -eq 0 ]
    # Verify it's valid JSON
    python3 -c "import json; json.loads('''$output''')" || {
        echo "Output is not valid JSON"
        return 1
    }
    cleanup_tmp
}

@test "14. quarantine status output is valid JSON" {
    setup_tmp_lockfile
    run_health_lockfile "${TMP_LOCKFILE}" --agent linux-desktop-seed
    [ "$status" -eq 0 ]
    # Verify it's valid JSON
    python3 -c "import json; json.loads('''$output''')" || {
        echo "Output is not valid JSON"
        return 1
    }
    cleanup_tmp
}

# ---------------------------------------------------------------------------
# Tests — Missing lockfile
# ---------------------------------------------------------------------------

@test "15. health check with missing lockfile" {
    run python3 "${HEALTH_SCRIPT}" --lockfile "/nonexistent/path/agents.lock.toml" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"lockfile"* ]]
    cleanup_tmp
}
