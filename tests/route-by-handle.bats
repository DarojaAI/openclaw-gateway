#!/usr/bin/env bats
#
# route-by-handle.bats — Tests for @handle routing via agents.lock.toml.
#
# Covers:
#   - Known @handle routes correctly
#   - Unknown @handle returns error
#   - Multiple @mentions in one message routes to first match
#   - Missing lockfile returns error
#   - Exit codes
#

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_SCRIPT="${REPO_ROOT}/scripts/route-by-handle.py"
LOCKFILE="${REPO_ROOT}/config/agents.lock.toml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run the Python route script with arguments.
run_route() {
    run python3 "${PYTHON_SCRIPT}" --lockfile "${LOCKFILE}" "$@"
}

# Run with custom lockfile
run_route_lockfile() {
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

[agents.darojaai_architect]
repo             = "DarojaAI/darojaai_architect"
handle           = "@darojaai-architect"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/darojaai_architect/blob/main/.openclaw/agent-config.yaml"
config_sha       = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"

[agents.mcp-tooling]
repo             = "DarojaAI/mcp-tooling"
handle           = "@mcp-tooling"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/mcp-tooling/blob/main/.openclaw/agent-config.yaml"
config_sha       = "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
EOF
}

# Create a minimal lockfile with one agent
setup_single_agent_lockfile() {
    TMP_LOCKFILE="$(mktemp)"
    cat > "${TMP_LOCKFILE}" << 'EOF'
schema_version = "1"

[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@linux-desktop-seed"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
EOF
}

# Clean up temp files
cleanup_tmp() {
    if [[ -n "${TMP_LOCKFILE:-}" && -f "${TMP_LOCKFILE}" ]]; then
        rm -f "${TMP_LOCKFILE}"
    fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "known @handle routes correctly (linux-desktop-seed)" {
    run_route --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
    [[ "$output" == *"DarojaAI/linux-desktop-seed"* ]]
    [[ "$output" == *"@linux-desktop-seed"* ]]
}

@test "known @handle routes correctly (darojaai-architect)" {
    run_route --handle @darojaai-architect
    [ "$status" -eq 0 ]
    [[ "$output" == *"darojaai_architect"* ]]
    [[ "$output" == *"DarojaAI/darojaai_architect"* ]]
}

@test "known @handle routes correctly (mcp-tooling)" {
    run_route --handle @mcp-tooling
    [ "$status" -eq 0 ]
    [[ "$output" == *"mcp-tooling"* ]]
    [[ "$output" == *"DarojaAI/mcp-tooling"* ]]
}

@test "unknown @handle returns error" {
    run_route --handle @unknown-agent
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown"* ]]
}

@test "no handle in input returns error" {
    run bash -c "echo 'hello world' | python3 '${PYTHON_SCRIPT}' --lockfile '${LOCKFILE}'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no @handle"* ]]
}

@test "multiple @mentions routes to first match" {
    run_route --message "@darojaai-architect hello @linux-desktop-seed"
    [ "$status" -eq 0 ]
    [[ "$output" == *"darojaai_architect"* ]]
    [[ "$output" != *"linux-desktop-seed"* ]]
}

@test "missing lockfile returns error" {
    run_route_lockfile "/nonexistent/path/agents.lock.toml" --handle @linux-desktop-seed
    [ "$status" -eq 2 ]
}

@test "lockfile with no agents section returns error on unknown handle" {
    setup_tmp_lockfile
    # Write an empty lockfile
    echo 'schema_version = "1"' > "${TMP_LOCKFILE}"
    run python3 "${PYTHON_SCRIPT}" --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown"* ]]
    cleanup_tmp
}

@test "handle in message text is found correctly" {
    run_route --message "hey @linux-desktop-seed check this out"
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
}

@test "shell wrapper works" {
    run "${REPO_ROOT}/scripts/route-by-handle.sh" --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
}

@test "shell wrapper with stdin works" {
    run bash -c "echo '@mcp-tooling hello' | ${REPO_ROOT}/scripts/route-by-handle.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mcp-tooling"* ]]
}

@test "shell wrapper handles unknown handle" {
    run "${REPO_ROOT}/scripts/route-by-handle.sh" --handle @does-not-exist
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown"* ]]
}

@test "exit code 0 for known handles" {
    run_route --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
}

@test "exit code 1 for unknown handles" {
    run_route --handle @nonexistent
    [ "$status" -eq 1 ]
}

@test "exit code 2 for missing lockfile" {
    run python3 "${PYTHON_SCRIPT}" --lockfile "/no/such/file" --handle @linux-desktop-seed
    [ "$status" -eq 2 ]
}
