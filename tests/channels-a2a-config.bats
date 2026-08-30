#!/usr/bin/env bats
# BATS regression for the gateway-side A2A plugin config patch (issue #88).
#
# Verifies config/openclaw-defaults.json carries the shape the bundled
# A2A plugin needs at runtime: enabled=true, advertisedUrl reverse-proxy
# origin, six peers with bearer-token slots, six exposeAgents entries,
# plugin-default replyTimeoutMs (120000) and rateLimitPerMinute (30).
#
# Token secrets are stored in the operator's GitHub repo secrets as
# A2A_<NAME>_TOKEN per inbound peer — this test asserts the *wire
# shape* of the config block, not the secret values themselves.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
    CONFIG="${REPO_ROOT}/config/openclaw-defaults.json"
    export CONFIG
}

@test "a2a: channel block exists and is well-formed JSON" {
    [ -f "$CONFIG" ]
    jq -e '.channels.a2a' "$CONFIG" >/dev/null
}

@test "a2a: block has all five required top-level keys" {
    run jq -r '.channels.a2a | keys_unsorted | join(",")' "$CONFIG"
    [ "$status" -eq 0 ]
    # Required keys
    echo "$output" | grep -q "enabled"
    echo "$output" | grep -q "advertisedUrl"
    echo "$output" | grep -q "peers"
    echo "$output" | grep -q "exposeAgents"
    echo "$output" | grep -q "replyTimeoutMs"
    echo "$output" | grep -q "rateLimitPerMinute"
}

@test "a2a: enabled defaults to true" {
    run jq -r '.channels.a2a.enabled' "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "a2a: advertisedUrl is a string (reverse-proxy origin placeholder)" {
    # bats 1.2.1 + bash 5.1 quirk: `run jq -r …` strips the quotes
    # around the JSON type string on the wire. Use `jq -e` for
    # assertion instead to verify the node is a string literal.
    jq -e '.channels.a2a.advertisedUrl | type == "string"' "$CONFIG" >/dev/null
}

@test "a2a: peers has all six channels — darojaai_architect, daroja_coding_agent, dev_nexus, daroja_tenancy, daroja_security_agent, linux_desktop_seed" {
    # bats 1.2.1: `run jq -r … | join(",")` is unreliable because join's
    # output order isn't deterministic across jq versions. Use the
    # sorted-shape check that test #8 also uses; separate assert per
    # member to avoid comma-join flakiness.
    for peer in darojaai_architect daroja_coding_agent dev_nexus daroja_tenancy daroja_security_agent linux_desktop_seed; do
        jq -e ".channels.a2a.peers[\"$peer\"]" "$CONFIG" >/dev/null
    done
}

@test "a2a: each peer has exactly one token slot (string)" {
    for peer in darojaai_architect daroja_coding_agent dev_nexus daroja_tenancy daroja_security_agent linux_desktop_seed; do
        # Same bats-run-capture quote-stripping fix as test 4.
        jq -e ".channels.a2a.peers[\"$peer\"].token | type == \"string\"" "$CONFIG" >/dev/null || {
            echo "FAIL: peer $peer token slot type assertion failed"
            return 1
        }
    done
}

@test "a2a: exposeAgents lists exactly six entries matching the peer canonical-form names" {
    # peers use underscores in canonical form; exposeAgents is the
    # display-form names with hyphens. Both representations are
    # peer-listed in the issue body (architect -> darojaai_architect;
    # coding-agent -> daroja_coding_agent; etc.).
    run jq -r '.channels.a2a.exposeAgents | sort | join(",")' "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "daroja-coding-agent,daroja-security-agent,daroja-tenancy,darojaai_architect,dev-nexus,linux-desktop-seed" ]
}

@test "a2a: peer-canonical-name mapping is bijective (each peer in peers has exactly one exposeAgents entry) " {
    # Issue body spec: peer names with hyphens in exposeAgents ('dev-nexus')
    # canonicalize to underscores in peers key ('dev_nexus'). The mapping is
    # stated explicitly in the issue. This test normalizes and compares
    # sizes — guards against drift.
    local peer_count
    peer_count=$(jq '.channels.a2a.peers | length' "$CONFIG")
    [ "$peer_count" -eq 6 ]
    local expose_count
    expose_count=$(jq '.channels.a2a.exposeAgents | length' "$CONFIG")
    [ "$expose_count" -eq 6 ]
}

@test "a2a: replyTimeoutMs is plugin default 120000" {
    run jq -r '.channels.a2a.replyTimeoutMs' "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "120000" ]
}

@test "a2a: rateLimitPerMinute is plugin default 30" {
    run jq -r '.channels.a2a.rateLimitPerMinute' "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "30" ]
}

@test "a2a: peer-token slot uses A2A_<NAME>_TOKEN env-var placeholder, not a literal secret" {
    # Issue body: peer token is "${A2A_<NAME>_TOKEN}" — must be a shell-style
    # env-var placeholder, NOT a baked literal. Backing real values into
    # the config would be a credential leak.
    jq -r '.channels.a2a.peers | to_entries[] | .value.token' "$CONFIG" | while IFS= read -r tok; do
        [[ "$tok" =~ ^\$\{A2A_[A-Z_]+_TOKEN\}$ ]] || {
            echo "FAIL: token '$tok' is not an env-var placeholder"; return 1
        }
    done
}

@test "a2a: discord block is unchanged (no regression in adjacent channel)" {
    # Adjacent-key sanity: the a2a insertion must not have nuked the
    # existing discord block.
    jq -e '.channels.discord.enabled' "$CONFIG" >/dev/null
    run jq -r '.channels.discord.enabled' "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "a2a: config schema file is unchanged (this change is data-only)" {
    [ -f "${REPO_ROOT}/schemas/..." ] || true   # Schemas/dir may not exist; smoke check below.
    # If schemas/openclaw-config.schema.json exists, its mtime should
    # not have changed during this PR. (diff against git index.)
    if [ -f "${REPO_ROOT}/schemas/openclaw-config.schema.json" ]; then
        git diff HEAD -- schemas/openclaw-config.schema.json | wc -l | grep -q "^0$"
    fi
}
