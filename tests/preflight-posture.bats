#!/usr/bin/env bats
#
# tests/preflight-posture.bats
#
# BATS tests for the P3 routing-posture check in scripts/preflight-gate.py
# (epic linux-desktop-seed#1857, P3 = gateway#125).
#
# What we're guarding
# -------------------
# When a posture registry is wired, the gate must reject any invocation
# whose route is missing / not in the agent's active routing-matrix set
# (L-001 §6: calls must match an active posture row). When unwired, the
# check must be skipped (posture: "skipped") so environments without the
# posture layer keep P0/P1/P2 behavior. A wired-but-unloadable registry
# must exit 2 (config error, fail-closed) — never allow-everything.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/preflight-gate.py"
    BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
    export BATS_TEST_TMPDIR
    WORK="$BATS_TEST_TMPDIR/preflight"
    mkdir -p "$WORK"

    # Known-principals registry (P0 attribution must pass so the tests
    # exercise the posture path, not fail on attribution).
    REGISTRY="$WORK/principals.json"
    cat > "$REGISTRY" <<'JSON'
{"version": 1, "principals": [{"id": "op-1234", "handle": "@milan"}]}
JSON

    # Posture registry: linux_desktop_seed has two active routes.
    POSTURE="$WORK/posture.json"
    cat > "$POSTURE" <<'JSON'
{"version": 1, "posture": {"linux_desktop_seed": ["lawyer_redline", "finance_close"]}}
JSON
}

@test "P3: wired + active route -> allow, posture ok" {
    run env PREFLIGHT_POSTURE_FILE="$POSTURE" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --route lawyer_redline \
        --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision": "allow"'
    echo "$output" | grep -q '"posture": "ok"'
}

@test "P3: wired + second active route -> allow" {
    run env PREFLIGHT_POSTURE_FILE="$POSTURE" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --route finance_close \
        --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"posture": "ok"'
}

@test "P3: wired + route not in active set -> reject (posture-mismatch)" {
    run env PREFLIGHT_POSTURE_FILE="$POSTURE" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --route secret_route \
        --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"decision": "reject"'
    echo "$output" | grep -q '"reason": "posture-mismatch"'
    echo "$output" | grep -q '"posture": "invalid"'
}

@test "P3: wired + no route requested -> reject (posture-route-missing)" {
    run env PREFLIGHT_POSTURE_FILE="$POSTURE" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed \
        --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "posture-route-missing"'
    echo "$output" | grep -q '"posture": "missing"'
}

@test "P3: wired via --posture-file flag (not env) -> enforced" {
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --route secret_route --posture-file "$POSTURE" --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"posture": "invalid"'
}

@test "P3: agent with no route set -> reject (posture-missing)" {
    # linux_headless_setup_curator has no posture rows.
    run env PREFLIGHT_POSTURE_FILE="$POSTURE" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_headless_setup_curator --route lawyer_redline \
        --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "posture-missing"'
}

@test "P3: registry unwired -> posture skipped, P0 allow unchanged" {
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --route lawyer_redline --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"posture": "skipped"'
}

@test "P3: wired but registry file missing -> exit 2 (fail-closed)" {
    run env PREFLIGHT_POSTURE_FILE="$WORK/does-not-exist.json" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --route lawyer_redline \
        --principals "$REGISTRY"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"decision": "reject"'
    echo "$output" | grep -q '"reason": "posture-registry-unavailable"'
}

@test "P3: wired but registry invalid json -> exit 2 (fail-closed)" {
    BAD="$WORK/bad-posture.json"
    echo 'not json' > "$BAD"
    run env PREFLIGHT_POSTURE_FILE="$BAD" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --route lawyer_redline \
        --principals "$REGISTRY"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"decision": "reject"'
}

@test "P3: --check reports posture-registry wiring" {
    run python3 "$SCRIPT" --check --posture-file "$POSTURE" --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'posture-registry=wired'
    run python3 "$SCRIPT" --check --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'posture-registry=unwired'
}

@test "P3: repo posture registry is valid JSON v1 shape" {
    run python3 -c "
import json
with open('$REPO_ROOT/config/preflight-posture.json') as f:
    d = json.load(f)
assert d['version'] == 1
assert isinstance(d['posture'], dict)
"
    [ "$status" -eq 0 ]
}