#!/usr/bin/env bats
#
# tests/preflight-tenant.bats
#
# BATS tests for the P1 tenant-model check in scripts/preflight-gate.py
# (epic linux-desktop-seed#1857, P1 = gateway#121).
#
# What we're guarding
# -------------------
# When TENANCY_BROKER_URL is wired, the gate must verify the invocation's
# tenant context against the daroja-tenancy round-2 broker surface
# (POST /auth/verify -> {triple, valid, exp}) and REJECT fail-closed on
# missing/invalid/unverifiable context. When unwired, the check must be
# skipped (tenant: "skipped") so environments without tenancy keep
# working exactly as P0. If either regresses: an unwired env starts
# blocking everything, or a wired env lets unverified tenant context
# through onto real client matter.
#
# We drive the CLI with a mock broker (tests/helpers/mock-tenancy-broker.sh)
# serving canned /auth/verify responses, mirroring the
# mock-openrouter.sh pattern.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/preflight-gate.py"
    BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
    export BATS_TEST_TMPDIR
    WORK="$BATS_TEST_TMPDIR/preflight"
    mkdir -p "$WORK"

    # Known-principals registry (P0 attribution must pass so the test is
    # really exercising the tenant path, not failing on attribution).
    REGISTRY="$WORK/principals.json"
    cat > "$REGISTRY" <<'JSON'
{"version": 1, "principals": [{"id": "op-1234", "handle": "@milan"}]}
JSON

    # Start the mock tenancy broker on a per-test port.
    MOCK="$REPO_ROOT/tests/helpers/mock-tenancy-broker.sh"
    _base=$((18766 + (RANDOM % 200)))
    export MOCK_PORT="$_base"
    FIXTURES="$REPO_ROOT/tests/helpers/fixtures"
    # The mock writes its request log next to the impl
    # (tests/helpers/requests.log, NOT inside fixtures/) and truncates
    # it on startup.
    REQUESTS_LOG="$REPO_ROOT/tests/helpers/requests.log"

    rm -rf "$FIXTURES"; mkdir -p "$FIXTURES"
    "$MOCK" "$MOCK_PORT" >"$BATS_TEST_TMPDIR/mock.stdout" 2>"$BATS_TEST_TMPDIR/mock.stderr" &
    MOCK_PID=$!
    # Wait for the mock to accept connections.
    for _ in $(seq 1 50); do
        if (echo > "/dev/tcp/127.0.0.1/$MOCK_PORT") 2>/dev/null; then break; fi
        sleep 0.1
    done
    # Debug: surface mock start diagnostics on failure.
    if ! (echo > "/dev/tcp/127.0.0.1/$MOCK_PORT") 2>/dev/null; then
        echo "MOCK STDOUT: $(cat "$BATS_TEST_TMPDIR/mock.stdout" 2>/dev/null)" >&3
        echo "MOCK STDERR: $(cat "$BATS_TEST_TMPDIR/mock.stderr" 2>/dev/null)" >&3
    fi
    export TENANCY_BROKER_URL="http://127.0.0.1:$MOCK_PORT"
}

teardown() {
    if [[ -n "${MOCK_PID:-}" ]]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    unset TENANCY_BROKER_URL PREFLIGHT_PRINCIPALS_FILE
}

# Valid round-2 verify response: triple + valid:true. The mock routes
# POST /auth/verify to fixtures/POST_verify.json (path /auth/verify
# normalizes to basename "_verify", mirroring mock-openrouter.sh).
valid_fixture() {
    cat > "$FIXTURES/POST_verify.json" <<'JSON'
{"triple": {"counterparty_id": "cp-1", "client_id": "cl-1", "project_id": "pj-1"}, "valid": true, "exp": 1893456000}
JSON
}

@test "P1: broker wired + valid JWT -> allow, tenant ok, triple surfaced" {
    valid_fixture
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --tenant-jwt "eyJhbGciOiJSUzI1NiJ9" --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision": "allow"'
    echo "$output" | grep -q '"tenant": "ok"'
    echo "$output" | grep -q '"counterparty_id": "cp-1"'
    # The mock actually received the verify call.
    grep -q 'POST /auth/verify' "$REQUESTS_LOG"
}

@test "P1: broker wired + invalid JWT (valid:false) -> reject fail-closed" {
    cat > "$FIXTURES/POST_verify.json" <<'JSON'
{"triple": null, "valid": false, "exp": null}
JSON
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --tenant-jwt "bad.jwt" --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"decision": "reject"'
    echo "$output" | grep -q '"reason": "tenant-jwt-invalid"'
    echo "$output" | grep -q '"tenant": "invalid"'
}

@test "P1: broker wired + HTTP 500 from verify -> reject fail-closed" {
    valid_fixture
    # Mock routes status to the same basename name as the body
    # (path /auth/verify -> _verify).
    echo 500 > "$FIXTURES/POST_verify.status"
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --tenant-jwt "eyJhbGciOiJSUzI1NiJ9" --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"tenant": "invalid"'
}

@test "P1: broker wired + no tenant context at all -> reject (tenant-missing)" {
    valid_fixture
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"decision": "reject"'
    echo "$output" | grep -q '"reason": "tenant-context-missing"'
    echo "$output" | grep -q '"tenant": "missing"'
}

@test "P1: broker wired + direct triple presence path -> allow" {
    valid_fixture
    run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
        --counterparty-id cp-9 --client-id cl-9 --project-id pj-9 \
        --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"tenant": "ok"'
    echo "$output" | grep -q '"counterparty_id": "cp-9"'
}

@test "P1: broker unwired -> tenant skipped, P0 allow unchanged" {
    # Local scope: temporarily unset the broker to simulate an unwired env.
    (
        unset TENANCY_BROKER_URL
        run python3 "$SCRIPT" evaluate --actor op-1234 --agent linux_desktop_seed \
            --tenant-jwt "any.jwt" --principals "$REGISTRY"
        [ "$status" -eq 0 ]
        echo "$output" | grep -q '"tenant": "skipped"'
    )
}

@test "P1: broker wired but unreachable -> reject fail-closed (no allow-everything)" {
    # Point at a dead port (nothing listening there).
    run env TENANCY_BROKER_URL="http://127.0.0.1:1" python3 "$SCRIPT" evaluate \
        --actor op-1234 --agent linux_desktop_seed --tenant-jwt "x" \
        --principals "$REGISTRY"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"reason": "tenant-broker-unreachable"'
}

@test "P1: --check reports tenant-broker wiring" {
    run python3 "$SCRIPT" --check --principals "$REGISTRY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'tenant-broker=wired'
}
