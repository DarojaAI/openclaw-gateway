#!/usr/bin/env bats
#
# tests/preflight-gate.bats
#
# BATS tests for scripts/preflight-gate.py — the per-invocation pre-LLM
# operator-attribution gate (epic linux-desktop-seed#1857, P0 = gateway#119).
#
# What we're guarding
# -------------------
# The gate decides, before any LLM call lands, whether an invocation's
# actor resolves to a known principal. It fails CLOSED: missing actor,
# unknown actor, or missing agent must REJECT; a missing/invalid
# registry must also reject (never allow-everything). Every decision
# emits a preflight.decision.v1 JSON event. If any of these regress,
# either unauthorized invocations get through (attribution goes dark)
# or everything blocks with no error surface.
#
# The test surface is the CLI (the hook entry point): evaluate with
# known/unknown/missing actor, missing agent, --check mode, event-log
# emission, and the fail-closed registry paths. We drive it with a
# synthetic principals registry under a temporary dir.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/preflight-gate.py"
    BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
    export BATS_TEST_TMPDIR
    WORK="$BATS_TEST_TMPDIR/preflight"
    mkdir -p "$WORK"

    # Synthetic principals registry with two known principals.
    REGISTRY="$WORK/principals.json"
    cat > "$REGISTRY" <<'JSON'
{"version": 1, "principals": [
  {"id": "op-1234", "handle": "@milan"},
  {"id": "daroja_coding_agent", "handle": "@daroja_coding_agent"}
]}
JSON
}

@test "preflight-gate.py evaluate: known actor by id -> allow (exit 0)" {
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision": "allow"'
    echo "$output" | grep -q '"reason": "actor-known"'
}

@test "preflight-gate.py evaluate: known actor by @handle -> allow (exit 0)" {
    run python3 "$SCRIPT" evaluate --actor @milan --agent linux_desktop_seed --principals "$REGISTRY"
    [ "$status" -eq 0 ]
}

@test "preflight-gate.py evaluate: unknown actor -> reject (exit 1)" {
    run python3 "$SCRIPT" evaluate --actor attacker-999 --agent linux_desktop_seed --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"decision": "reject"'
    echo "$output" | grep -q '"reason": "actor-unknown"'
}

@test "preflight-gate.py evaluate: missing actor -> reject, fail-closed (exit 1)" {
    run python3 "$SCRIPT" evaluate --agent linux_desktop_seed --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "actor-missing"'
}

@test "preflight-gate.py evaluate: empty actor -> reject, fail-closed (exit 1)" {
    run python3 "$SCRIPT" evaluate --actor "" --agent linux_desktop_seed --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "actor-missing"'
}

@test "preflight-gate.py evaluate: missing agent -> reject, fail-closed (exit 1)" {
    run python3 "$SCRIPT" evaluate --actor op-1234 --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "agent-missing"'
}

@test "preflight-gate.py evaluate: event carries preflight.decision.v1 shape" {
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --capability write --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"event": "preflight.decision.v1"'
    echo "$output" | grep -q '"agentId": "linux_desktop_seed"'
    echo "$output" | grep -q '"principalKnown": true'
    # Valid JSON on stdout
    python3 -c "import json,sys; json.loads(sys.stdin.read())" <<< "$output"
}

@test "preflight-gate.py evaluate: rejection event has principalKnown false" {
    run python3 "$SCRIPT" evaluate --actor attacker-999 --agent linux_desktop_seed \
        --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"principalKnown": false'
}

@test "preflight-gate.py evaluate: --event-log appends one JSON line per call" {
    LOG="$WORK/events.log"
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --principals "$REGISTRY" --event-log "$LOG"
    [ "$status" -eq 0 ]
    run python3 "$SCRIPT" evaluate --actor attacker-999 --agent linux_desktop_seed \
        --principals "$REGISTRY" --event-log "$LOG"
    [ "$status" -eq 1 ]
    # Exactly two lines, each valid JSON.
    [ "$(wc -l < "$LOG")" -eq 2 ]
    python3 -c "
import json
lines = open('$LOG').read().splitlines()
assert len(lines) == 2
for line in lines:
    e = json.loads(line)
    assert e['event'] == 'preflight.decision.v1'
assert json.loads(lines[0])['decision'] == 'allow'
assert json.loads(lines[1])['decision'] == 'reject'
"
}

@test "preflight-gate.py evaluate: registry loaded from PREFLIGHT_PRINCIPALS_FILE env" {
    PREFLIGHT_PRINCIPALS_FILE="$REGISTRY" run python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed
    [ "$status" -eq 0 ]
}

@test "preflight-gate.py evaluate: missing registry file -> exit 2 (fail-closed, no allow-everything)" {
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --principals "$WORK/does-not-exist.json"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"decision": "reject"'
    echo "$output" | grep -q '"reason": "registry-unavailable"'
}

@test "preflight-gate.py evaluate: invalid registry json -> exit 2 (fail-closed)" {
    BAD="$WORK/bad.json"
    echo 'not json' > "$BAD"
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --principals "$BAD"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"decision": "reject"'
}

@test "preflight-gate.py --check: prints state and exits 0" {
    run python3 "$SCRIPT" --check --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "principals=2"
}

@test "preflight-gate.py --check: missing registry -> exit 2" {
    run python3 "$SCRIPT" --check --principals "$WORK/does-not-exist.json"
    [ "$status" -eq 2 ]
}

@test "preflight-gate.py: unknown subcommand -> exit 2" {
    run python3 "$SCRIPT" bogus
    [ "$status" -eq 2 ]
}

@test "preflight-gate.py: repo principals registry is valid JSON v1 shape" {
    run python3 -c "
import json
with open('$REPO_ROOT/config/preflight-principals.json') as f:
    d = json.load(f)
assert d['version'] == 1
assert isinstance(d['principals'], list)
"
    [ "$status" -eq 0 ]
}