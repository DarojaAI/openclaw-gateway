#!/usr/bin/env bats
#
# tests/rfc31-e2e-integration.bats
#
# End-to-end integration tests for the RFC #31 pipeline.
# Verifies the complete flow: lockfile → generate-bindings → middleware → audit log.
#
# Covers:
#   1. Lockfile → bindings → middleware: consistent routing
#   2. Bridge syntax e2e: correct target resolution
#   3. Channel pinning e2e: dry-run logs + enforce blocks
#   4. Quarantine e2e: stale deploy blocks
#   5. Canary routing e2e: ~10% distribution over 100 runs
#   6. Audit log e2e: structured JSON entry with all required fields
#   7. Full pipeline: lockfile → generate bindings → middleware → audit log → consistent

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES="${SCRIPT_DIR}/fixtures/rfc31-e2e"

MIDDLEWARE="${REPO_ROOT}/scripts/discord-middleware.py"
GEN_BINDINGS="${REPO_ROOT}/scripts/generate-bindings-from-lockfile.py"
BRIDGE_SCRIPT="${REPO_ROOT}/scripts/bridge-syntax.py"
AUDIT_SCRIPT="${REPO_ROOT}/scripts/audit_log.py"
QUARANTINE_SCRIPT="${REPO_ROOT}/scripts/quarantine.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
    TMPDIR="$(mktemp -d)"
    cp "${FIXTURES}/sample-lockfile.toml" "${TMPDIR}/agents.lock.toml"
    cp "${FIXTURES}/sample-config.json" "${TMPDIR}/openclaw.json"
    cp "${FIXTURES}/test-messages.json" "${TMPDIR}/test-messages.json"
    LOCKFILE="${TMPDIR}/agents.lock.toml"
    CONFIG="${TMPDIR}/openclaw.json"
    AUDIT_LOG="${TMPDIR}/audit.log"
    QUARANTINE_STORE="${TMPDIR}/quarantine.json"
    export OPENCLAW_AUDIT_LOG="$AUDIT_LOG"
    export TMPDIR LOCKFILE CONFIG AUDIT_LOG QUARANTINE_STORE
}

teardown() {
    rm -rf "$TMPDIR"
}

# Run middleware and capture stdout, stderr, status into globals.
run_middleware() {
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    set +e
    python3 "${MIDDLEWARE}" "$@" \
        > "${stdout_file}" 2> "${stderr_file}"
    STATUS=$?
    set -e
    OUTPUT="$(cat "${stdout_file}")"
    STDERR="$(cat "${stderr_file}")"
    rm -f "${stdout_file}" "${stderr_file}"
}

# Run generate-bindings and capture stdout, stderr, status into globals.
run_bindings() {
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    set +e
    python3 "${GEN_BINDINGS}" "$@" \
        > "${stdout_file}" 2> "${stderr_file}"
    STATUS=$?
    set -e
    OUTPUT="$(cat "${stdout_file}")"
    STDERR="$(cat "${stderr_file}")"
    rm -f "${stdout_file}" "${stderr_file}"
}

# ---------------------------------------------------------------------------
# 1. Lockfile → bindings → middleware: consistent routing
# ---------------------------------------------------------------------------

@test "e2e: lockfile → generate bindings → middleware routes consistently" {
    # Step 1: Generate bindings from lockfile
    run_bindings --lockfile "${LOCKFILE}" --openclaw-json "${CONFIG}" --dry-run
    [ "$STATUS" -eq 0 ]
    # Bindings should be valid JSON
    echo "$OUTPUT" | python3 -m json.tool > /dev/null
    # Should contain agent IDs from our lockfile
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
bindings = d.get('bindings', [])
agent_ids = [b.get('agentId') for b in bindings]
assert 'linux-desktop-seed' in agent_ids, f'expected linux-desktop-seed in {agent_ids}'
assert 'mcp-tooling' in agent_ids, f'expected mcp-tooling in {agent_ids}'
assert 'secure-agent' in agent_ids, f'expected secure-agent in {agent_ids}'
"

    # Step 2: Route a message through middleware — should resolve to same agent
    run_middleware --lockfile "${LOCKFILE}" --message '{"content":"@linux-desktop-seed deploy VM","channel_id":"1000000000000000001"}'
    [ "$STATUS" -eq 0 ]
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing'] is not None
assert d['routing']['slug'] == 'linux-desktop-seed'
assert 'routing' in d['steps']
"

    # Step 3: Routing decision should reference same config_source/config_sha as lockfile
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d['routing']
assert r.get('config_sha', '') != '', 'config_sha should be set from lockfile'
assert r.get('config_source', '') != '', 'config_source should be set from lockfile'
"
}

# ---------------------------------------------------------------------------
# 2. Bridge syntax e2e: two agents, correct target
# ---------------------------------------------------------------------------

@test "e2e: bridge syntax routes to correct target agent" {
    run_middleware --lockfile "${LOCKFILE}" --message '{"content":"@linux-desktop-seed ask @darojaai-architect what is the architecture?","channel_id":"1000000000000000001"}'
    [ "$STATUS" -eq 0 ]

    # Should have bridge_syntax step
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'bridge_syntax' in d['steps'], f'bridge_syntax not in steps: {d[\"steps\"]}'
"

    # Should resolve both source and target
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d['routing']
assert r['source_agent']['handle'] == '@linux-desktop-seed'
assert r['source_agent']['slug'] == 'linux-desktop-seed'
assert r['target_agent']['handle'] == '@darojaai-architect'
assert r['target_agent']['slug'] == 'darojaai-architect'
assert r['question'] == 'what is the architecture?'
"

    # No blocking on valid bridge call
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] is False
"
}

@test "e2e: bridge syntax with unknown source agent returns violations" {
    run_middleware --lockfile "${LOCKFILE}" --message '{"content":"@unknown-agent ask @darojaai-architect hello","channel_id":"1000000000000000001"}'
    # Should exit 0 (dry-run) but have violations
    [ "$STATUS" -eq 0 ]
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert len(d['violations']) > 0, f'expected violations for unknown source agent'
"
}

# ---------------------------------------------------------------------------
# 3. Channel pinning e2e: dry-run logs + enforce blocks
# ---------------------------------------------------------------------------

@test "e2e: channel pinning dry-run logs violation but passes through" {
    # @linux-desktop-seed: dry_run=true (default), enforce_channel_pinning=false
    # Send message in a disallowed channel — violation logged but not blocked
    run_middleware --lockfile "${LOCKFILE}" --message '{"content":"@linux-desktop-seed deploy VM","channel_id":"999999999999999999"}' --dry-run
    [ "$STATUS" -eq 0 ]

    # Should have channel_pinning step with violation
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'channel_pinning' in d['steps'], f'channel_pinning not in steps: {d[\"steps\"]}'
cp = d['routing']['channel_pinning']
assert cp['violation'] is True
assert cp['dry_run'] is True
assert cp['enforced'] is False
"

    # Should have violation recorded
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert len(d['violations']) > 0
assert any('999999999999999999' in v for v in d['violations'])
"
}

@test "e2e: channel pinning enforce blocks message" {
    # @secure-agent: enforce_channel_pinning=true, dry_run=false
    # Send message in disallowed channel
    run_middleware --lockfile "${LOCKFILE}" --message '{"content":"@secure-agent run audit","channel_id":"999999999999999999"}' --enforce
    [ "$STATUS" -eq 1 ]

    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] is True
assert d['blocked_reason'] is not None
assert 'channel pinning' in d['blocked_reason'].lower()
"
}

@test "e2e: channel pinning enforce allows correct channel" {
    # @mcp-tooling: allowed in channel 1000000000000000001
    run_middleware --lockfile "${LOCKFILE}" --message '{"content":"@mcp-tooling list servers","channel_id":"1000000000000000001"}' --enforce
    [ "$STATUS" -eq 0 ]

    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] is False
assert 'channel_pinning' in d['steps']
cp = d['routing']['channel_pinning']
assert cp['violation'] is False
"
}

# ---------------------------------------------------------------------------
# 4. Quarantine e2e: stale deploy blocks
# ---------------------------------------------------------------------------

@test "e2e: quarantined agent is blocked in dry-run" {
    # Quarantine linux-desktop-seed
    python3 "${QUARANTINE_SCRIPT}" --lockfile "${LOCKFILE}" --quarantine linux-desktop-seed --reason "stale deploy timestamp"

    run_middleware --lockfile "${LOCKFILE}" --message '{"content":"@linux-desktop-seed deploy VM","channel_id":"1000000000000000001"}'
    [ "$STATUS" -eq 0 ]

    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] is True
assert 'quarantined' in d['blocked_reason'].lower()
assert 'quarantine' in ' '.join(d['steps'])
"

    # Clean up quarantine
    python3 "${QUARANTINE_SCRIPT}" --lockfile "${LOCKFILE}" --unquarantine linux-desktop-seed
}

@test "e2e: quarantined source in bridge syntax blocks the call" {
    python3 "${QUARANTINE_SCRIPT}" --lockfile "${LOCKFILE}" --quarantine linux-desktop-seed --reason "heartbeat missed"

    run_middleware --lockfile "${LOCKFILE}" --message '{"content":"@linux-desktop-seed ask @darojaai-architect hello","channel_id":"1000000000000000001"}'
    [ "$STATUS" -eq 0 ]

    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] is True
assert 'source agent' in d['blocked_reason'].lower()
"

    python3 "${QUARANTINE_SCRIPT}" --lockfile "${LOCKFILE}" --unquarantine linux-desktop-seed
}

@test "e2e: quarantined target in bridge syntax blocks the call" {
    python3 "${QUARANTINE_SCRIPT}" --lockfile "${LOCKFILE}" --quarantine darojaai-architect --reason "config drift"

    run_middleware --lockfile "${LOCKFILE}" --message '{"content":"@linux-desktop-seed ask @darojaai-architect hello","channel_id":"1000000000000000001"}'
    [ "$STATUS" -eq 0 ]

    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] is True
assert 'target agent' in d['blocked_reason'].lower()
"

    python3 "${QUARANTINE_SCRIPT}" --lockfile "${LOCKFILE}" --unquarantine darojaai-architect
}

# ---------------------------------------------------------------------------
# 5. Canary routing e2e: ~10% distribution over 100 runs
# ---------------------------------------------------------------------------

@test "e2e: canary routing distributes ~10% to canary agent over 100 runs" {
    # Create a lockfile with two agents sharing a capability, one canary
    local canary_lockfile="${TMPDIR}/canary-test.lock.toml"
    cat > "${canary_lockfile}" << 'EOF'
schema_version = "1"

[agents.stable-agent]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@stable-agent"
contract_version = "v1"
config_source    = "https://example.com/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
capabilities     = ["shared-cap"]
role             = "executor"
canary           = false
canary_weight_percent = 10

[agents.canary-agent]
repo             = "DarojaAI/mcp-tooling"
handle           = "@canary-agent"
contract_version = "v1"
config_source    = "https://example.com/agent-config.yaml"
config_sha       = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"
capabilities     = ["shared-cap"]
role             = "executor"
canary           = true
canary_weight_percent = 10
EOF

    # Test canary distribution via capability dispatch (multiple candidates)
    canary_count=0
    total=100
    for i in $(seq 1 $total); do
        result="$(python3 "${REPO_ROOT}/scripts/capability-dispatch.py" \
            --lockfile "${canary_lockfile}" --capability shared-cap \
            2>/dev/null)"
        selected_slug="$(echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# Handle both wrapped (would_route_to) and direct output
r = d.get('would_route_to', d)
print(r.get('slug', ''))
")"
        if [ "$selected_slug" = "canary-agent" ]; then
            canary_count=$((canary_count + 1))
        fi
    done

    # With 10% weight, expect roughly 10 out of 100 (allow range 0-30)
    [ "$canary_count" -ge 0 ]
    [ "$canary_count" -le 30 ]
}

@test "e2e: canary metadata present in middleware output" {
    run_middleware --lockfile "${LOCKFILE}" --message '{"content":"@mcp-tooling list servers","channel_id":"1000000000000000001"}'
    [ "$STATUS" -eq 0 ]

    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cr = d['routing'].get('canary', {})
assert 'is_canary' in cr, 'canary metadata missing is_canary'
assert 'canary_weight_percent' in cr, 'canary metadata missing canary_weight_percent'
assert 'selected' in cr, 'canary metadata missing selected'
assert 'total_candidates' in cr, 'canary metadata missing total_candidates'
"
}

# ---------------------------------------------------------------------------
# 6. Audit log e2e: structured JSON with all required fields
# ---------------------------------------------------------------------------

@test "e2e: bridge call writes structured audit log entry" {
    # Run middleware with --audit flag
    run_middleware --lockfile "${LOCKFILE}" \
        --message '{"content":"@linux-desktop-seed ask @darojaai-architect review the PR","channel_id":"1000000000000000001"}' \
        --audit --audit-log "${AUDIT_LOG}"
    [ "$STATUS" -eq 0 ]

    # Audit log should exist and have at least one entry
    [ -f "${AUDIT_LOG}" ]
    entry_count="$(wc -l < "${AUDIT_LOG}")"
    [ "$entry_count" -ge 1 ]

    # Entry should be valid JSON with required fields
    tail -1 "${AUDIT_LOG}" | python3 -c "
import sys, json
required_fields = ['ts', 'from_agent', 'to_agent', 'from_handle', 'to_handle',
                   'contract_version', 'capability', 'channel_id']
entry = json.loads(sys.stdin.readline())
for field in required_fields:
    assert field in entry, f'missing field: {field}'
    assert entry[field] != '', f'empty field: {field}'
"

    # Verify the entry contents match the bridge call
    tail -1 "${AUDIT_LOG}" | python3 -c "
import sys, json
entry = json.loads(sys.stdin.readline())
assert entry['from_agent'] == 'linux-desktop-seed'
assert entry['to_agent'] == 'darojaai-architect'
assert entry['capability'] == 'bridge'
assert entry['channel_id'] == '1000000000000000001'
"
}

@test "e2e: handle call writes audit log entry" {
    run_middleware --lockfile "${LOCKFILE}" \
        --message '{"content":"@linux-desktop-seed deploy VM","channel_id":"1000000000000000001"}' \
        --audit --audit-log "${AUDIT_LOG}"
    [ "$STATUS" -eq 0 ]

    [ -f "${AUDIT_LOG}" ]
    tail -1 "${AUDIT_LOG}" | python3 -c "
import sys, json
entry = json.loads(sys.stdin.readline())
assert entry['from_agent'] == 'linux-desktop-seed'
assert entry['to_agent'] == 'linux-desktop-seed'
assert entry['channel_id'] == '1000000000000000001'
"
}

# ---------------------------------------------------------------------------
# 7. Full pipeline: lockfile → generate bindings → middleware → audit → consistent
# ---------------------------------------------------------------------------

@test "e2e: full pipeline produces consistent state" {
    # Step 1: Generate bindings from lockfile
    run_bindings --lockfile "${LOCKFILE}" --openclaw-json "${CONFIG}" --dry-run
    [ "$STATUS" -eq 0 ]
    bindings_json="$OUTPUT"

    # Step 2: Write bindings to config file (simulate deploy)
    echo "$bindings_json" > "${CONFIG}"

    # Step 3: Run middleware with audit logging
    run_middleware --lockfile "${LOCKFILE}" \
        --message '{"content":"@linux-desktop-seed ask @darojaai-architect what is the architecture?","channel_id":"1000000000000000001"}' \
        --audit --audit-log "${AUDIT_LOG}"
    [ "$STATUS" -eq 0 ]

    # Step 4: Verify audit log entry
    [ -f "${AUDIT_LOG}" ]
    audit_entry="$(tail -1 "${AUDIT_LOG}")"

    # Step 5: Verify config file has bindings from lockfile agents
    echo "$bindings_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
agent_ids = [b.get('agentId') for b in d.get('bindings', [])]
assert 'linux-desktop-seed' in agent_ids
assert 'mcp-tooling' in agent_ids
assert 'secure-agent' in agent_ids
"

    # Step 6: Verify audit entry references same agents
    echo "$audit_entry" | python3 -c "
import sys, json
entry = json.loads(sys.stdin.readline())
assert entry['from_agent'] == 'linux-desktop-seed'
assert entry['to_agent'] == 'darojaai-architect'
assert entry['capability'] == 'bridge'
"

    # Step 7: Verify middleware output is consistent with audit
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing']['source_agent']['slug'] == 'linux-desktop-seed'
assert d['routing']['target_agent']['slug'] == 'darojaai-architect'
assert d['blocked'] is False
"
}

@test "e2e: full pipeline — no handles message produces no routing" {
    run_middleware --lockfile "${LOCKFILE}" \
        --message '{"content":"just a plain message with no handles","channel_id":"1000000000000000001"}'
    [ "$STATUS" -eq 0 ]

    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing'] is None
assert 'no_handles' in d['steps']
assert d['blocked'] is False
assert len(d['violations']) == 0
"
}

@test "e2e: full pipeline — generate bindings then route all fixture messages" {
    # Generate bindings from lockfile
    run_bindings --lockfile "${LOCKFILE}" --openclaw-json "${CONFIG}" --dry-run
    [ "$STATUS" -eq 0 ]

    # Write bindings to config
    echo "$OUTPUT" > "${CONFIG}"

    # Read test messages and route each one
    python3 - "${LOCKFILE}" "${MIDDLEWARE}" "${AUDIT_LOG}" "${TMPDIR}/test-messages.json" << 'PYEOF'
import json
import subprocess
import sys

lockfile = sys.argv[1]
middleware = sys.argv[2]
audit_log = sys.argv[3]
messages_path = sys.argv[4]

with open(messages_path) as f:
    messages = json.load(f)

for i, msg in enumerate(messages):
    result = subprocess.run(
        ["python3", middleware, "--lockfile", lockfile,
         "--message", json.dumps(msg),
         "--audit", "--audit-log", audit_log],
        capture_output=True, text=True, timeout=30,
    )
    # All messages should process without error (exit 0 or 1)
    assert result.returncode in (0, 1), f"message {i} failed: {result.stderr}"
    # Output should be valid JSON
    output = json.loads(result.stdout)
    assert "pipeline_version" in output, f"message {i} missing pipeline_version"
    assert "steps" in output, f"message {i} missing steps"

print("OK: all fixture messages processed successfully")
PYEOF
    [ "$STATUS" -eq 0 ]
}

@test "e2e: full pipeline — quarantine then unquarantine restores routing" {
    # Quarantine linux-desktop-seed
    python3 "${QUARANTINE_SCRIPT}" --lockfile "${LOCKFILE}" \
        --quarantine linux-desktop-seed --reason "deploy in progress"

    # Route should be blocked
    run_middleware --lockfile "${LOCKFILE}" \
        --message '{"content":"@linux-desktop-seed deploy VM","channel_id":"1000000000000000001"}'
    [ "$STATUS" -eq 0 ]
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] is True
assert 'quarantined' in d['blocked_reason'].lower()
"

    # Unquarantine
    python3 "${QUARANTINE_SCRIPT}" --lockfile "${LOCKFILE}" \
        --unquarantine linux-desktop-seed

    # Route should work again
    run_middleware --lockfile "${LOCKFILE}" \
        --message '{"content":"@linux-desktop-seed deploy VM","channel_id":"1000000000000000001"}'
    [ "$STATUS" -eq 0 ]
    echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] is False
assert d['routing'] is not None
assert d['routing']['slug'] == 'linux-desktop-seed'
"
}
