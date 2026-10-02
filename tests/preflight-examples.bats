#!/usr/bin/env bats
#
# tests/preflight-examples.bats
#
# BATS tests for the P4.2 rollout artifacts: the EXAMPLE registries under
# config/examples/preflight/ and the runtime-hook invocation example in
# docs/contracts/preflight-v1.md (epic linux-desktop-seed#1857,
# P4.2 = gateway#127).
#
# What we're guarding
# -------------------
# The example registries are the operator's on-ramp to the gate: if they
# stop parsing with preflight-gate.py's loaders, or stop producing the
# allow/reject outcomes the contract doc documents, the rollout exit
# criteria ("copy the examples, point the env vars, see --check + one
# allow + one reject") break and the runtime-hook wiring example lies.
# We also pin that the canonical config/preflight-*.json stay EMPTY
# templates (DAT contract: env-specific values are injected at deploy,
# never hardcoded in canonical config).
#
# The examples are deliberately NOT production data: placeholder ids
# (@example-operator-*, EXAMPLE-* tenant ids), one granted + one revoked
# capability per pilot agent (daroja-lawyer-agent, daroja-finance-agent,
# linux_desktop_seed), and an explicit active route set per agent.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/preflight-gate.py"
    EXAMPLES="$REPO_ROOT/config/examples/preflight"
    BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
    export BATS_TEST_TMPDIR
    WORK="$BATS_TEST_TMPDIR/preflight-examples"
    mkdir -p "$WORK"

    # Tenant broker unwired unless a test wires it: the documented
    # example outcomes assume tenant: "skipped".
    unset TENANCY_BROKER_URL

    # Deploy-style env injection pointed at the example registries (the
    # same wiring the contract doc's runtime-hook example uses).
    export PREFLIGHT_PRINCIPALS_FILE="$EXAMPLES/principals.example.json"
    export PREFLIGHT_CONSENT_FILE="$EXAMPLES/consent.example.json"
    export PREFLIGHT_POSTURE_FILE="$EXAMPLES/posture.example.json"
}

@test "P4.2: example registries wired via env -> --check exits 0, all layers reported" {
    run python3 "$SCRIPT" --check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "principals=2"
    echo "$output" | grep -q "consent-registry=wired"
    echo "$output" | grep -q "posture-registry=wired"
    echo "$output" | grep -q "tenant-broker=unwired (check skipped)"
}

@test "P4.2: example registries parse with the gate's loaders (importlib)" {
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('preflight_gate', '$SCRIPT')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
principals = mod.load_principals('$EXAMPLES/principals.example.json')
consent = mod.load_consent('$EXAMPLES/consent.example.json')
posture = mod.load_posture('$EXAMPLES/posture.example.json')
assert len(principals) == 2, principals
assert consent['daroja-lawyer-agent']['draft_redline'] == 'granted'
assert consent['daroja-lawyer-agent']['external_send'] == 'revoked'
assert consent['daroja-finance-agent']['wire_transfer'] == 'revoked'
assert posture['daroja-finance-agent'] == ['finance_close', 'invoice_review']
assert 'lane_ops' in posture['linux_desktop_seed']
"
    [ "$status" -eq 0 ]
}

@test "P4.2: example registry shapes are v1 with the pilot agent set" {
    run python3 -c "
import json
p = json.load(open('$EXAMPLES/principals.example.json'))
c = json.load(open('$EXAMPLES/consent.example.json'))
s = json.load(open('$EXAMPLES/posture.example.json'))
assert p['version'] == 1 and isinstance(p['principals'], list) and len(p['principals']) == 2
pilot = {'daroja-lawyer-agent', 'daroja-finance-agent', 'linux_desktop_seed'}
assert set(c['consent']) == pilot, set(c['consent'])
assert set(s['posture']) == pilot, set(s['posture'])
for grants in c['consent'].values():
    assert 'granted' in grants.values() and 'revoked' in grants.values()
"
    [ "$status" -eq 0 ]
}

@test "P4.2: pilot lanes allow on granted capability + active route (lawyer/finance/infra)" {
    run python3 "$SCRIPT" evaluate --actor @example-operator-0001 \
        --agent daroja-lawyer-agent --capability draft_redline --route legal_redline
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision": "allow"'
    echo "$output" | grep -q '"consent": "ok"'
    echo "$output" | grep -q '"posture": "ok"'
    run python3 "$SCRIPT" evaluate --actor @example-operator-0002 \
        --agent daroja-finance-agent --capability invoice_reconcile --route finance_close
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision": "allow"'
    run python3 "$SCRIPT" evaluate --actor @example-operator-0001 \
        --agent linux_desktop_seed --capability lane_maintenance --route lane_ops
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision": "allow"'
}

@test "P4.2: contract-doc example invocation -> ALLOW (lawyer draft_redline, exit 0)" {
    run python3 "$SCRIPT" evaluate \
        --actor @example-operator-0001 --agent daroja-lawyer-agent \
        --capability draft_redline --route legal_redline \
        --counterparty-id EXAMPLE-cp-001 \
        --client-id EXAMPLE-client-001 --project-id EXAMPLE-project-001
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"event": "preflight.decision.v1"'
    echo "$output" | grep -q '"agentId": "daroja-lawyer-agent"'
    echo "$output" | grep -q '"decision": "allow"'
    echo "$output" | grep -q '"reason": "actor-known"'
    echo "$output" | grep -q '"principalKnown": true'
    echo "$output" | grep -q '"tenant": "skipped"'
    echo "$output" | grep -q '"consent": "ok"'
    echo "$output" | grep -q '"posture": "ok"'
}

@test "P4.2: contract-doc example invocation -> REJECT consent-revoked (exit 1)" {
    run python3 "$SCRIPT" evaluate \
        --actor @example-operator-0001 --agent daroja-lawyer-agent \
        --capability external_send --route legal_redline \
        --counterparty-id EXAMPLE-cp-001 \
        --client-id EXAMPLE-client-001 --project-id EXAMPLE-project-001
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"decision": "reject"'
    echo "$output" | grep -q '"reason": "consent-revoked"'
    echo "$output" | grep -q '"consent": "revoked"'
    echo "$output" | grep -q '"posture": "ok"'
}

@test "P4.2: example data rejects revoked capability on finance lane (wire_transfer)" {
    run python3 "$SCRIPT" evaluate --actor @example-operator-0002 \
        --agent daroja-finance-agent --capability wire_transfer --route finance_close
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "consent-revoked"'
    echo "$output" | grep -q '"consent": "revoked"'
}

@test "P4.2: example data rejects route outside active set (posture-mismatch)" {
    run python3 "$SCRIPT" evaluate --actor @example-operator-0001 \
        --agent linux_desktop_seed --capability lane_maintenance --route finance_close
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "posture-mismatch"'
    echo "$output" | grep -q '"posture": "invalid"'
}

@test "P4.2: example data rejects unknown actor fail-closed (actor-unknown)" {
    run python3 "$SCRIPT" evaluate --actor @no-such-operator \
        --agent linux_desktop_seed --capability lane_maintenance --route infra_maintenance
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "actor-unknown"'
    echo "$output" | grep -q '"principalKnown": false'
}

@test "P4.2: contract doc pins the runtime-hook invocation example" {
    DOC="$REPO_ROOT/docs/contracts/preflight-v1.md"
    grep -q "Runtime-hook invocation example" "$DOC"
    grep -q "before_route_inbound_message" "$DOC"
    grep -q -- "--capability draft_redline --route legal_redline" "$DOC"
    grep -q -- "--capability external_send --route legal_redline" "$DOC"
    grep -q '"decision": "allow"' "$DOC"
    grep -q '"reason": "consent-revoked"' "$DOC"
    grep -q "tests/preflight-examples.bats" "$DOC"
}

@test "P4.2: --event-log appends one allow + one reject JSON line (example data)" {
    LOG="$WORK/events.log"
    run python3 "$SCRIPT" evaluate --actor @example-operator-0001 \
        --agent daroja-lawyer-agent --capability draft_redline --route legal_redline \
        --event-log "$LOG"
    [ "$status" -eq 0 ]
    run python3 "$SCRIPT" evaluate --actor @example-operator-0001 \
        --agent daroja-lawyer-agent --capability external_send --route legal_redline \
        --event-log "$LOG"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$LOG")" -eq 2 ]
    python3 -c "
import json
lines = open('$LOG').read().splitlines()
assert json.loads(lines[0])['decision'] == 'allow'
assert json.loads(lines[1])['decision'] == 'reject'
assert json.loads(lines[1])['reason'] == 'consent-revoked'
"
}

@test "P4.2: canonical preflight registries stay empty templates (DAT contract)" {
    run python3 -c "
import json
root = '$REPO_ROOT/config'
assert json.load(open(root + '/preflight-principals.json'))['principals'] == []
assert json.load(open(root + '/preflight-consent.json'))['consent'] == {}
assert json.load(open(root + '/preflight-posture.json'))['posture'] == {}
"
    [ "$status" -eq 0 ]
}
