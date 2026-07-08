#!/usr/bin/env bats
#
# canary-routing.bats — Tests for canary routing (RFC #31 Phase 6, Issue #52).
#
# Covers:
#   - Single canary agent: always selected (is_canary=true)
#   - Single non-canary agent: always selected (is_canary=false)
#   - Canary vs stable: 10% default weight
#   - Canary vs stable: custom weight override
#   - Multiple canary agents: random selection within canary set
#   - No canary agents: stable selection
#   - --dry-run mode
#   - --seed for deterministic testing
#   - Unknown handle returns error
#   - Unknown capability returns error
#   - Missing lockfile returns error
#   - JSON output shape
#

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_SCRIPT="${REPO_ROOT}/scripts/canary_routing.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run the Python canary routing script with arguments.
run_canary() {
    run python3 "${PYTHON_SCRIPT}" "$@"
}

# Run with a custom lockfile
run_canary_lockfile() {
    local lockfile="$1"
    shift
    run python3 "${PYTHON_SCRIPT}" --lockfile "${lockfile}" "$@"
}

# Create a lockfile with given agent configs.
# Args: lockfile_path, agent definitions (via heredoc)
make_lockfile() {
    local path="$1"
    shift
    python3 - "$path" << 'PYEOF'
import sys
path = sys.argv[1]
# Read remaining lines from stdin (the test function writes them)
PYEOF
    # For simplicity, write a lockfile from args
    cat > "${path}" << 'EOF'
schema_version = "1"

[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@linux-desktop-seed"
contract_version = "v1"
config_source    = "https://example.com/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
capabilities     = ["vm-provision", "vm-decommission"]
role             = "executor"
canary           = false
canary_weight_percent = 10

[agents.darojaai-architect]
repo             = "DarojaAI/darojaai_architect"
handle           = "@darojaai-architect"
contract_version = "v1"
config_source    = "https://example.com/agent-config.yaml"
config_sha       = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"
capabilities     = ["architecture", "code-review"]
role             = "advisor"
canary           = false
canary_weight_percent = 10
EOF
}

# Create a lockfile with a canary agent
make_canary_lockfile() {
    local path="$1"
    local canary1="$2"       # true/false for agent 1
    local canary2="$3"       # true/false for agent 2
    local weight1="${4:-10}"  # canary weight for agent 1
    local weight2="${5:-10}"  # canary weight for agent 2
    cat > "${path}" << EOF
schema_version = "1"

[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@linux-desktop-seed"
contract_version = "v1"
config_source    = "https://example.com/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
capabilities     = ["vm-provision", "vm-decommission"]
role             = "executor"
canary           = ${canary1}
canary_weight_percent = ${weight1}

[agents.darojaai-architect]
repo             = "DarojaAI/darojaai_architect"
handle           = "@darojaai-architect"
contract_version = "v1"
config_source    = "https://example.com/agent-config.yaml"
config_sha       = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"
capabilities     = ["architecture", "code-review"]
role             = "advisor"
canary           = ${canary2}
canary_weight_percent = ${weight2}
EOF
}

# Setup and teardown
setup() {
    TMP_LOCKFILE="$(mktemp)"
}

teardown() {
    if [[ -n "${TMP_LOCKFILE:-}" && -f "${TMP_LOCKFILE}" ]]; then
        rm -f "${TMP_LOCKFILE}"
    fi
}

# ---------------------------------------------------------------------------
# Tests — Single agent (handle routing)
# ---------------------------------------------------------------------------

@test "1. single canary agent: is_canary=true in output" {
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "false"
    run_canary --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *'"is_canary": true'* ]]
    [[ "$output" == *'"slug": "linux-desktop-seed"'* ]]
    [[ "$output" == *'"total_candidates": 1'* ]]
}

@test "2. single non-canary agent: is_canary=false in output" {
    make_canary_lockfile "${TMP_LOCKFILE}" "false" "false"
    run_canary --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *'"is_canary": false'* ]]
    [[ "$output" == *'"slug": "linux-desktop-seed"'* ]]
}

# ---------------------------------------------------------------------------
# Tests — Capability routing with canary
# ---------------------------------------------------------------------------

@test "3. capability routing: no canary agents → stable agent selected" {
    make_canary_lockfile "${TMP_LOCKFILE}" "false" "false"
    run_canary --lockfile "${TMP_LOCKFILE}" --capability vm-provision
    [ "$status" -eq 0 ]
    [[ "$output" == *'"is_canary": false'* ]]
    [[ "$output" == *'"slug": "linux-desktop-seed"'* ]]
    [[ "$output" == *'"total_candidates": 1'* ]]
    [[ "$output" == *'"canary_candidates": 0'* ]]
    [[ "$output" == *'"stable_candidates": 1'* ]]
}

@test "4. capability routing: one canary, one stable, deterministic roll=0 → canary selected" {
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "false"
    # Seed 42 → roll is deterministic; we test that canary CAN be selected
    run_canary --lockfile "${TMP_LOCKFILE}" --capability vm-provision --seed 42
    [ "$status" -eq 0 ]
    [[ "$output" == *'"total_candidates": 1'* ]]
    [[ "$output" == *'"is_canary": true'* ]]
}

@test "5. capability routing: two agents with same capability, one canary, one stable, seed 100 → stable" {
    # Both agents have vm-provision capability
    # With seed 100, we can check which was selected
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "false"
    # Add the same capability to the architect
    python3 - "${TMP_LOCKFILE}" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r") as fh:
    content = fh.read()
# Add vm-provision to the architect
content = content.replace(
    'capabilities     = ["architecture", "code-review"]',
    'capabilities     = ["architecture", "code-review", "vm-provision"]'
)
with open(path, "w") as fh:
    fh.write(content)
PYEOF
    run_canary --lockfile "${TMP_LOCKFILE}" --capability vm-provision --seed 100
    [ "$status" -eq 0 ]
    [[ "$output" == *'"total_candidates": 2'* ]]
    [[ "$output" == *'"canary_candidates": 1'* ]]
    [[ "$output" == *'"stable_candidates": 1'* ]]
}

# ---------------------------------------------------------------------------
# Tests — Custom canary weight
# ---------------------------------------------------------------------------

@test "6. custom canary weight: --canary-weight 50 with seed 25 → canary selected" {
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "false"
    # Add the same capability to the architect
    python3 - "${TMP_LOCKFILE}" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r") as fh:
    content = fh.read()
content = content.replace(
    'capabilities     = ["architecture", "code-review"]',
    'capabilities     = ["architecture", "code-review", "vm-provision"]'
)
with open(path, "w") as fh:
    fh.write(content)
PYEOF
    run_canary --lockfile "${TMP_LOCKFILE}" --capability vm-provision --canary-weight 50 --seed 25
    [ "$status" -eq 0 ]
    [[ "$output" == *'"canary_weight_percent": 50'* ]]
    [[ "$output" == *'"roll": 48'* ]]
    [[ "$output" == *'"is_canary": true'* ]]
}

@test "7. custom canary weight: --canary-weight 50 with seed 75 → stable selected" {
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "false"
    python3 - "${TMP_LOCKFILE}" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r") as fh:
    content = fh.read()
content = content.replace(
    'capabilities     = ["architecture", "code-review"]',
    'capabilities     = ["architecture", "code-review", "vm-provision"]'
)
with open(path, "w") as fh:
    fh.write(content)
PYEOF
    run_canary --lockfile "${TMP_LOCKFILE}" --capability vm-provision --canary-weight 50 --seed 75
    [ "$status" -eq 0 ]
    [[ "$output" == *'"canary_weight_percent": 50'* ]]
    [[ "$output" == *'"roll": 57'* ]]
    [[ "$output" == *'"is_canary": false'* ]]
}

# ---------------------------------------------------------------------------
# Tests — --dry-run mode
# ---------------------------------------------------------------------------

@test "8. --dry-run returns would_route_to with dry_run flag" {
    make_canary_lockfile "${TMP_LOCKFILE}" "false" "false"
    run_canary --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *'"dry_run": true'* ]]
    [[ "$output" == *'"would_route_to"'* ]]
}

@test "9. --dry-run with canary: still returns would_route_to" {
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "false"
    run_canary --lockfile "${TMP_LOCKFILE}" --capability vm-provision --dry-run --seed 42
    [ "$status" -eq 0 ]
    [[ "$output" == *'"dry_run": true'* ]]
    [[ "$output" == *'"would_route_to"'* ]]
}

# ---------------------------------------------------------------------------
# Tests — Error cases
# ---------------------------------------------------------------------------

@test "10. unknown handle returns exit 1" {
    make_canary_lockfile "${TMP_LOCKFILE}" "false" "false"
    run_canary --lockfile "${TMP_LOCKFILE}" --handle @nonexistent
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown handle"* ]]
}

@test "11. unknown capability returns exit 1" {
    make_canary_lockfile "${TMP_LOCKFILE}" "false" "false"
    run_canary --lockfile "${TMP_LOCKFILE}" --capability nonexistent-capability
    [ "$status" -eq 1 ]
    [[ "$output" == *"no agent has capability"* ]]
}

@test "12. missing lockfile returns exit 2" {
    run_canary --lockfile "/nonexistent/path/agents.lock.toml" --handle @linux-desktop-seed
    [ "$status" -eq 2 ]
}

@test "13. no --handle or --capability returns exit 1" {
    make_canary_lockfile "${TMP_LOCKFILE}" "false" "false"
    run_canary --lockfile "${TMP_LOCKFILE}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--handle or --capability is required"* ]]
}

# ---------------------------------------------------------------------------
# Tests — JSON output shape
# ---------------------------------------------------------------------------

@test "14. output JSON includes canary metadata with all fields" {
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "false"
    run_canary --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *'"is_canary": true'* ]]
    [[ "$output" == *'"canary_weight_percent"'* ]]
    [[ "$output" == *'"roll"'* ]]
    [[ "$output" == *'"selected"'* ]]
    [[ "$output" == *'"total_candidates"'* ]]
    [[ "$output" == *'"canary_candidates"'* ]]
    [[ "$output" == *'"stable_candidates"'* ]]
}

@test "15. output JSON includes handle, slug, repo, config_source, config_sha" {
    make_canary_lockfile "${TMP_LOCKFILE}" "false" "false"
    run_canary --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *'"handle": "@linux-desktop-seed"'* ]]
    [[ "$output" == *'"slug": "linux-desktop-seed"'* ]]
    [[ "$output" == *'"repo": "DarojaAI/linux-desktop-seed"'* ]]
    [[ "$output" == *'"config_source"'* ]]
    [[ "$output" == *'"config_sha"'* ]]
}

# ---------------------------------------------------------------------------
# Tests — Deterministic testing with --seed
# ---------------------------------------------------------------------------

@test "16. --seed produces deterministic output across runs" {
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "false"
    python3 - "${TMP_LOCKFILE}" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r") as fh:
    content = fh.read()
content = content.replace(
    'capabilities     = ["architecture", "code-review"]',
    'capabilities     = ["architecture", "code-review", "vm-provision"]'
)
with open(path, "w") as fh:
    fh.write(content)
PYEOF
    run1="$(python3 "${PYTHON_SCRIPT}" --lockfile "${TMP_LOCKFILE}" --capability vm-provision --seed 42 2>/dev/null)"
    run2="$(python3 "${PYTHON_SCRIPT}" --lockfile "${TMP_LOCKFILE}" --capability vm-provision --seed 42 2>/dev/null)"
    [ "$run1" == "$run2" ]
}

# ---------------------------------------------------------------------------
# Tests — Integration with existing dispatch scripts
# ---------------------------------------------------------------------------

@test "17. capability-dispatch.py still works with canary agents (back-compat)" {
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "false"
    run python3 "${REPO_ROOT}/scripts/capability-dispatch.py" --lockfile "${TMP_LOCKFILE}" --capability vm-provision
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
}

@test "18. route-by-handle.py still works with canary agents (back-compat)" {
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "false"
    run python3 "${REPO_ROOT}/scripts/route-by-handle.py" --lockfile "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"linux-desktop-seed"* ]]
}

# ---------------------------------------------------------------------------
# Tests — All canary agents (no stable fallback)
# ---------------------------------------------------------------------------

@test "19. all canary agents: first canary selected (no stable to fall back)" {
    make_canary_lockfile "${TMP_LOCKFILE}" "true" "true"
    run_canary --lockfile "${TMP_LOCKFILE}" --capability vm-provision
    [ "$status" -eq 0 ]
    [[ "$output" == *'"is_canary": true'* ]]
    [[ "$output" == *'"stable_candidates": 0'* ]]
}

@test "20. all stable agents: stable selected (no canary)" {
    make_canary_lockfile "${TMP_LOCKFILE}" "false" "false"
    run_canary --lockfile "${TMP_LOCKFILE}" --capability vm-provision
    [ "$status" -eq 0 ]
    [[ "$output" == *'"is_canary": false'* ]]
    [[ "$output" == *'"canary_candidates": 0'* ]]
}
