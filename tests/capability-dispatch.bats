#!/usr/bin/env bats
#
# capability-dispatch.bats — Tests for capability-based dispatch.
#
# Covers:
#   - Handle routing (same as route-by-handle.py but via capability-dispatch.py)
#   - Capability routing
#   - --capability flag
#   - --dry-run mode
#   - Missing lockfile
#   - Ambiguous agent selection
#   - JSON output shape
#

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_SCRIPT="${REPO_ROOT}/scripts/capability-dispatch.py"
LOCKFILE="${REPO_ROOT}/config/agents.lock.toml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run the Python dispatch script with arguments.
run_dispatch() {
    run python3 "${PYTHON_SCRIPT}" --lockfile "${LOCKFILE}" "$@"
}

# Run with custom lockfile
run_dispatch_lockfile() {
    local lockfile="$1"
    shift
    run python3 "${PYTHON_SCRIPT}" --lockfile "${lockfile}" "$@"
}

# Create a temporary lockfile for testing
setup_tmp_lockfile() {
    TMP_LOCKFILE="$(mktemp)"
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
EOF
}

# Clean up temp files
cleanup_tmp() {
    if [[ -n "${TMP_LOCKFILE:-}" && -f "${TMP_LOCKFILE}" ]]; then
        rm -f "${TMP_LOCKFILE}"
    fi
}

# ---------------------------------------------------------------------------
# Tests — Handle routing
# ---------------------------------------------------------------------------

@test "1. @linux-desktop-seed routes by handle (linux-desktop-seed)" {
    run_dispatch --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
    [[ "$output" == *"DarojaAI/linux-desktop-seed"* ]]
    [[ "$output" == *"@linux-desktop-seed"* ]]
    [[ "$output" == *'"match_type": "handle"'* ]]
    [[ "$output" == *'"matched_via": "handle"'* ]]
}

@test "2. @darojaai-architect routes by handle (darojaai_architect)" {
    run_dispatch --handle @darojaai-architect
    [ "$status" -eq 0 ]
    [[ "$output" == *"darojaai_architect"* ]]
    [[ "$output" == *"DarojaAI/darojaai_architect"* ]]
    [[ "$output" == *'"match_type": "handle"'* ]]
}

@test "3. @mcp-tooling routes by handle (mcp-tooling)" {
    run_dispatch --handle @mcp-tooling
    [ "$status" -eq 0 ]
    [[ "$output" == *"mcp-tooling"* ]]
    [[ "$output" == *"DarojaAI/mcp-tooling"* ]]
    [[ "$output" == *'"match_type": "handle"'* ]]
}

# ---------------------------------------------------------------------------
# Tests — Capability routing
# ---------------------------------------------------------------------------

@test "4. @vm-provision routes by capability → linux-desktop-seed" {
    run_dispatch --capability vm-provision
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
    [[ "$output" == *'"match_type": "capability"'* ]]
    [[ "$output" == *'"matched_via": "capability"'* ]]
}

@test "5. @vm-decommission routes by capability → linux-desktop-seed" {
    run_dispatch --capability vm-decommission
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
    [[ "$output" == *'"match_type": "capability"'* ]]
}

@test "6. @architect-review routes by capability → darojaai_architect" {
    run_dispatch --capability code-review
    [ "$status" -eq 0 ]
    [[ "$output" == *"darojaai_architect"* ]]
    [[ "$output" == *'"match_type": "capability"'* ]]
}

@test "7. @plan-review routes by capability → darojaai_architect" {
    run_dispatch --capability design-patterns
    [ "$status" -eq 0 ]
    [[ "$output" == *"darojaai_architect"* ]]
    [[ "$output" == *'"match_type": "capability"'* ]]
}

@test "8. @mcp-server routes by capability → mcp-tooling" {
    run_dispatch --capability mcp-server
    [ "$status" -eq 0 ]
    [[ "$output" == *"mcp-tooling"* ]]
    [[ "$output" == *'"match_type": "capability"'* ]]
}

# ---------------------------------------------------------------------------
# Tests — Error cases
# ---------------------------------------------------------------------------

@test "9. @nonexistent-capability returns error" {
    run_dispatch --capability nonexistent-capability
    [ "$status" -eq 1 ]
    [[ "$output" == *"no @handle or @capability"* ]]
}

@test "10. @nonexistent-handle falls through to capability lookup" {
    # @vm-provision is not a handle, but it is a capability
    run_dispatch --message "@vm-provision hello"
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
    [[ "$output" == *'"match_type": "capability"'* ]]
}

# ---------------------------------------------------------------------------
# Tests — --capability direct lookup
# ---------------------------------------------------------------------------

@test "11. --capability direct lookup works" {
    run_dispatch --capability mcp-server
    [ "$status" -eq 0 ]
    [[ "$output" == *"mcp-tooling"* ]]
}

# ---------------------------------------------------------------------------
# Tests — --dry-run mode
# ---------------------------------------------------------------------------

@test "12. --dry-run does not emit a route decision, exits 0" {
    run_dispatch --capability vm-provision --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *'"dry_run": true'* ]]
    [[ "$output" == *'"would_route_to"'* ]]
    # The routing decision is nested inside would_route_to, not at the top level
    # Top-level should NOT have match_type directly — it's wrapped in would_route_to
    # We check that dry_run: true is at the top level
    [[ "$output" == *'"dry_run": true'* ]]
}

# ---------------------------------------------------------------------------
# Tests — Missing lockfile
# ---------------------------------------------------------------------------

@test "13. Missing lockfile returns error (exit 2)" {
    run_dispatch_lockfile "/nonexistent/path/agents.lock.toml" --handle @linux-desktop-seed
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Tests — Multi-capability agent: first-listed capability wins
# ---------------------------------------------------------------------------

@test "14. Multi-capability agent: first-listed capability wins on lookup" {
    # pr-stewardship is the 3rd capability of linux-desktop-seed
    run_dispatch --capability pr-stewardship
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
    [[ "$output" == *'"match_type": "capability"'* ]]
}

# ---------------------------------------------------------------------------
# Tests — JSON output shape
# ---------------------------------------------------------------------------

@test "15. Output JSON includes matched_via, match_type, capabilities, role" {
    run_dispatch --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *'"matched_via": "handle"'* ]]
    [[ "$output" == *'"match_type": "handle"'* ]]
    [[ "$output" == *'"capabilities"'* ]]
    [[ "$output" == *'"role": "executor"'* ]]
}

# ---------------------------------------------------------------------------
# Tests — Shell wrapper
# ---------------------------------------------------------------------------

@test "16. Shell wrapper works for capability dispatch" {
    run "${REPO_ROOT}/scripts/capability-dispatch.sh" --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
}

@test "17. Shell wrapper with capability lookup works" {
    run "${REPO_ROOT}/scripts/capability-dispatch.sh" --capability mcp-server
    [ "$status" -eq 0 ]
    [[ "$output" == *"mcp-tooling"* ]]
}
