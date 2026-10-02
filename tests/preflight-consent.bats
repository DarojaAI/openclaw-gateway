#!/usr/bin/env bats
#
# tests/preflight-consent.bats
#
# BATS tests for the P2 capability-consent check in scripts/preflight-gate.py
# (epic linux-desktop-seed#1857, P2 = gateway#123).
#
# What we're guarding
# -------------------
# When a consent registry is wired, the gate must reject any invocation
# whose requested capability is missing/revoked for the agent (L-001 §3:
# silent capability introductions are rejected pre-flight). When unwired,
# the check must be skipped (consent: "skipped") so environments without
# the consent layer keep P0/P1 behavior. A wired-but-unloadable registry
# must exit 2 (config error, fail-closed) — never allow-everything.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/preflight-gate.py"
    BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
    export BATS_TEST_TMPDIR
    WORK="$BATS_TEST_TMPDIR/preflight"
    mkdir -p "$WORK"

    # Known-principals registry (P0 attribution must pass so the tests
    # exercise the consent path, not fail on attribution).
    REGISTRY="$WORK/principals.json"
    cat > "$REGISTRY" <<'JSON'
{"version": 1, "principals": [{"id": "op-1234", "handle": "@milan"}]}
JSON

    # Consent registry with one granted and one revoked capability.
    CONSENT="$WORK/consent.json"
    cat > "$CONSENT" <<'JSON'
{"version": 1, "consent": {"linux_desktop_seed": {"coding": "granted", "write": "revoked"}}}
JSON
}

@test "P2: wired + granted capability -> allow, consent ok" {
    run env PREFLIGHT_CONSENT_FILE="$CONSENT" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --capability coding \
        --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision": "allow"'
    echo "$output" | grep -q '"consent": "ok"'
}

@test "P2: wired + revoked capability -> reject fail-closed (consent-revoked)" {
    run env PREFLIGHT_CONSENT_FILE="$CONSENT" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --capability write \
        --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"decision": "reject"'
    echo "$output" | grep -q '"reason": "consent-revoked"'
    echo "$output" | grep -q '"consent": "revoked"'
}

@test "P2: wired + capability with no record -> reject fail-closed (consent-missing)" {
    run env PREFLIGHT_CONSENT_FILE="$CONSENT" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --capability deploy \
        --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "consent-missing"'
    echo "$output" | grep -q '"consent": "missing"'
}

@test "P2: wired + no capability requested -> reject (consent-capability-missing)" {
    run env PREFLIGHT_CONSENT_FILE="$CONSENT" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed \
        --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "consent-capability-missing"'
}

@test "P2: wired via --consent-file flag (not env) -> enforced" {
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --capability write --consent-file "$CONSENT" --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"consent": "revoked"'
}

@test "P2: registry unwired -> consent skipped, P0 allow unchanged" {
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --capability coding --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"consent": "skipped"'
}

@test "P2: wired but registry file missing -> exit 2 (fail-closed, no allow-everything)" {
    run env PREFLIGHT_CONSENT_FILE="$WORK/does-not-exist.json" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --capability coding \
        --principals "$REGISTRY"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"decision": "reject"'
    echo "$output" | grep -q '"reason": "consent-registry-unavailable"'
}

@test "P2: wired but registry file invalid json -> exit 2 (fail-closed)" {
    BAD="$WORK/bad-consent.json"
    echo 'not json' > "$BAD"
    run env PREFLIGHT_CONSENT_FILE="$BAD" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --capability coding \
        --principals "$REGISTRY"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"decision": "reject"'
}

@test "P2: consent agent has no record -> reject (consent-missing)" {
    # A different agent (linux_headless_setup_curator) has no grants.
    run env PREFLIGHT_CONSENT_FILE="$CONSENT" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_headless_setup_curator --capability coding \
        --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "consent-missing"'
}

@test "P2: --check reports consent-registry wiring" {
    run python3 "$SCRIPT" --check --consent-file "$CONSENT" --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'consent-registry=wired'
    run python3 "$SCRIPT" --check --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'consent-registry=unwired'
}

@test "P2: repo consent registry is valid JSON v1 shape" {
    run python3 -c "
import json
with open('$REPO_ROOT/config/preflight-consent.json') as f:
    d = json.load(f)
assert d['version'] == 1
assert isinstance(d['consent'], dict)
"
    [ "$status" -eq 0 ]
}