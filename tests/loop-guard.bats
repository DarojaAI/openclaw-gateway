#!/usr/bin/env bats

# loop-guard.bats — Tests for loop guard behavior
# Default: loop guard ON (agent should NOT respond)
# Per-agent override: loop_guard: false means agent CAN respond

setup() {
    SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    LOOP_GUARD="${SCRIPT_DIR}/scripts/loop-guard.py"
    export TMPDIR="$(mktemp -d)"
    export LOCKFILE="${TMPDIR}/agents.lock.toml"
}

teardown() {
    rm -rf "${TMPDIR}"
}

write_lockfile() {
    echo "$1" > "${LOCKFILE}"
}

# --- Test: agent with loop_guard: false → should respond ---
@test "agent with loop_guard: false → should respond" {
    write_lockfile '[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
loop_guard       = false

[agents.darojaai-architect]
repo             = "DarojaAI/darojaai_architect"
loop_guard       = true
'
    run python3 "${LOOP_GUARD}" --source darojaai-architect --target linux-desktop-seed --lockfile "${LOCKFILE}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"should_respond": true'* ]]
}

# --- Test: agent with loop_guard: true → should NOT respond ---
@test "agent with loop_guard: true → should NOT respond" {
    write_lockfile '[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
loop_guard       = false

[agents.darojaai-architect]
repo             = "DarojaAI/darojaai_architect"
loop_guard       = true
'
    run python3 "${LOOP_GUARD}" --source linux-desktop-seed --target darojaai-architect --lockfile "${LOCKFILE}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"should_respond": false'* ]]
}

# --- Test: missing lockfile → should NOT respond ---
@test "missing lockfile → should NOT respond" {
    run python3 "${LOOP_GUARD}" --source agent-a --target agent-b --lockfile "${TMPDIR}/nonexistent.toml"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"should_respond": false'* ]]
}

# --- Test: default (no loop_guard field) → should NOT respond ---
@test "default (no loop_guard field) → should NOT respond" {
    write_lockfile '[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
'
    run python3 "${LOOP_GUARD}" --source agent-a --target linux-desktop-seed --lockfile "${LOCKFILE}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"should_respond": false'* ]]
}

# --- Test: target agent not in lockfile → should NOT respond ---
@test "target agent not in lockfile → should NOT respond" {
    write_lockfile '[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
loop_guard       = false
'
    run python3 "${LOOP_GUARD}" --source linux-desktop-seed --target unknown-agent --lockfile "${LOCKFILE}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"should_respond": false'* ]]
}

# --- Test: output is valid JSON ---
@test "output is valid JSON" {
    write_lockfile '[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
loop_guard       = false
'
    run python3 "${LOOP_GUARD}" --source linux-desktop-seed --target darojaai-architect --lockfile "${LOCKFILE}"
    [ "$status" -eq 0 ]
    # Validate JSON
    python3 -c "import json; json.loads('''${output}''')"
}

# --- Test: shell wrapper produces same result ---
@test "shell wrapper produces same result" {
    write_lockfile '[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
loop_guard       = false
'
    run bash "${SCRIPT_DIR}/scripts/loop-guard.sh" --source agent-b --target linux-desktop-seed --lockfile "${LOCKFILE}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"should_respond": true'* ]]
}
