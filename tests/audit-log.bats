#!/usr/bin/env bats
#
# audit-log.bats — Tests for audit log (RFC #31 Phase 6, Issue #51).
#
# Covers:
#   - write: append one JSON line to audit log
#   - write: creates log file if not exists (mode 0600)
#   - write: appends multiple entries (one per call)
#   - query: filter by from_agent
#   - query: filter by to_agent
#   - query: filter by capability
#   - query: filter by from+to
#   - query: empty result when no entries match
#   - query: empty log returns nothing
#   - bridge-syntax integration: --audit flag writes to audit log
#

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUDIT_SCRIPT="${REPO_ROOT}/scripts/audit_log.py"
BRIDGE_SCRIPT="${REPO_ROOT}/scripts/bridge-syntax.py"
LOCKFILE="${REPO_ROOT}/config/agents.lock.toml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a temporary audit log path
setup() {
    TMP_AUDIT="$(mktemp)"
    export OPENCLAW_AUDIT_LOG="$TMP_AUDIT"
}

teardown() {
    rm -f "$TMP_AUDIT"
}

# Write an entry directly (capture stdout to avoid BATS merge)
run_write() {
    python3 "${AUDIT_SCRIPT}" write \
        --from-agent "$1" \
        --to-agent "$2" \
        --from-handle "@$1" \
        --to-handle "@$2" \
        --contract-version "$3" \
        --capability "$4" \
        --channel-id "$5" \
        --log-path "$TMP_AUDIT" 2>/dev/null
}

# Query entries (capture stdout only)
run_query() {
    python3 "${AUDIT_SCRIPT}" query \
        "$@" \
        --log-path "$TMP_AUDIT" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Write tests
# ---------------------------------------------------------------------------

@test "write: appends one JSON line" {
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    [ -f "$TMP_AUDIT" ]
    local count
    count=$(wc -l < "$TMP_AUDIT")
    [ "$count" -eq 1 ]
}

@test "write: creates log file with mode 0600" {
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    local mode
    mode=$(stat -c %a "$TMP_AUDIT")
    [ "$mode" = "600" ]
}

@test "write: appends multiple entries" {
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    run_write "mcp-tooling" "linux-desktop-seed" "v1" "vm-provision" "1501612164098687087"
    local count
    count=$(wc -l < "$TMP_AUDIT")
    [ "$count" -eq 2 ]
}

@test "write: entry is valid JSON" {
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    python3 -c "
import json
with open('$TMP_AUDIT') as f:
    entry = json.loads(f.readline())
"
}

@test "write: entry contains expected fields" {
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    python3 -c "
import json
with open('$TMP_AUDIT') as f:
    entry = json.loads(f.readline())
assert entry['from_agent'] == 'linux-desktop-seed'
assert entry['to_agent'] == 'darojaai_architect'
assert entry['contract_version'] == 'v1'
assert entry['capability'] == 'architect-review'
assert entry['channel_id'] == '1501612164098687087'
assert 'ts' in entry
"
}

# ---------------------------------------------------------------------------
# Query tests
# ---------------------------------------------------------------------------

@test "query: filter by from_agent" {
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    run_write "mcp-tooling" "darojaai_architect" "v1" "skill-review" "1501612164098687087"
    local result
    result=$(run_query --from "linux-desktop-seed")
    [ -n "$result" ]
    echo "$result" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().strip().split('\n') if l]
assert len(lines) == 1
entry = json.loads(lines[0])
assert entry['from_agent'] == 'linux-desktop-seed'
"
}

@test "query: filter by to_agent" {
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    run_write "linux-desktop-seed" "mcp-tooling" "v1" "skill-review" "1501612164098687087"
    local result
    result=$(run_query --to "mcp-tooling")
    [ -n "$result" ]
    echo "$result" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().strip().split('\n') if l]
assert len(lines) == 1
entry = json.loads(lines[0])
assert entry['to_agent'] == 'mcp-tooling'
"
}

@test "query: filter by capability" {
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "skill-review" "1501612164098687087"
    local result
    result=$(run_query --capability "skill-review")
    [ -n "$result" ]
    echo "$result" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().strip().split('\n') if l]
assert len(lines) == 1
entry = json.loads(lines[0])
assert entry['capability'] == 'skill-review'
"
}

@test "query: filter by from+to" {
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    run_write "linux-desktop-seed" "mcp-tooling" "v1" "skill-review" "1501612164098687087"
    run_write "mcp-tooling" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    local result
    result=$(run_query --from "linux-desktop-seed" --to "darojaai_architect")
    [ -n "$result" ]
    echo "$result" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().strip().split('\n') if l]
assert len(lines) == 1
entry = json.loads(lines[0])
assert entry['from_agent'] == 'linux-desktop-seed'
assert entry['to_agent'] == 'darojaai_architect'
"
}

@test "query: empty result when no entries match" {
    run_write "linux-desktop-seed" "darojaai_architect" "v1" "architect-review" "1501612164098687087"
    local result
    result=$(run_query --from "nonexistent-agent")
    echo "$result" | grep -q "No audit entries found."
}

@test "query: empty log returns nothing" {
    local result
    result=$(run_query --from "linux-desktop-seed")
    echo "$result" | grep -q "No audit entries found."
}

# ---------------------------------------------------------------------------
# Bridge-syntax integration
# ---------------------------------------------------------------------------

@test "bridge-syntax: --audit flag writes audit log entry" {
    TMP_BRIDGE_LOCK="$(mktemp)"
    cat > "${TMP_BRIDGE_LOCK}" << 'EOF'
schema_version = "1"

[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@linux-desktop-seed"
contract_version = "v1"
config_source    = "https://example.com/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
capabilities     = ["vm-provision"]
role             = "executor"
allowed_channels = ["1501612164098687087"]

[agents.darojaai_architect]
repo             = "DarojaAI/darojaai_architect"
handle           = "@darojaai-architect"
contract_version = "v1"
config_source    = "https://example.com/agent-config.yaml"
config_sha       = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"
capabilities     = ["architect-review"]
role             = "advisor"
allowed_channels = ["1501612164098687087"]
EOF

    python3 "${BRIDGE_SCRIPT}" \
        "@linux-desktop-seed ask @darojaai-architect what is the architecture?" \
        "${TMP_BRIDGE_LOCK}" \
        --audit \
        --contract-version v1 \
        --capability architect-review \
        --channel-id 1501612164098687087 \
        --log-path "$TMP_AUDIT" >/dev/null 2>&1
    [ -f "$TMP_AUDIT" ]
    # Audit log should have one entry
    local count
    count=$(wc -l < "$TMP_AUDIT")
    [ "$count" -eq 1 ]
    # Entry should have correct from_agent and to_agent
    python3 -c "
import json
with open('$TMP_AUDIT') as f:
    entry = json.loads(f.readline())
assert entry['from_agent'] == 'linux-desktop-seed'
assert entry['to_agent'] == 'darojaai-architect'
assert entry['capability'] == 'architect-review'
"
    rm -f "${TMP_BRIDGE_LOCK}"
}
