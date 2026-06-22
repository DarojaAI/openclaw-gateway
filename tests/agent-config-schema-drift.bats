#!/usr/bin/env bats
#
# Load-bearing drift guardrail for schemas/agent-config.schema.json.
#
# What we're guarding
# -------------------
# Phase-1 deliverable for RFC issue #31 (agent-config schema +
# drift guardrail). The committed schema is the source of truth
# for per-agent `.openclaw/agent-config.yaml` files. If a future
# CI step — e.g. `scripts/ci/refresh-openclaw-schema.sh` — tries
# to overwrite the committed schema with `openclaw config schema`
# from the binary pinned in `config/openclaw-version`, the
# constraints we wrote (the `pattern`s, the `enum`s, the
# `required` list, `additionalProperties:false`) silently get
# dropped. The binary schema is the binary's accepted config
# SHAPE, not the agent-config shape — they are different things.
#
# Why a separate bats file
# ------------------------
# `agent-config-schema.bats` proves the schema's structure. This
# file proves the schema's structure SURVIVES any future attempt
# to "refresh" it from the binary dump. The two together close
# the gap between (a) "is the schema correct?" and (b) "will the
# schema still be correct after the next automated refresh?"
#
# Modeled on
# ----------
# ~/GithubProjects/linux-desktop-seed/tests/openclaw-schema-secretref.bats
# which guards the same failure mode for openclaw-config.schema.json.
#
# Skipping tests
# --------------
# If the openclaw binary is not on PATH, this entire file is
# effectively useless (we can't compare against the binary dump).
# Tests skip individually so a partial install is still useful.
#
# Known limitations
# -----------------
# Two of the requested cases ("binary accepts the schema's
# required handle pattern" and "binary dump does not forbid our
# handle_id field name") are too speculative to write robustly:
# we cannot predict where the binary might define a `handle`
# property, or whether it might use `handle_id` as a forbidden
# field at some nested path. We document this in the source
# rather than ship flaky tests.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCHEMA_FILE="${REPO_ROOT}/schemas/agent-config.schema.json"
    VERSION_FILE="${REPO_ROOT}/config/openclaw-version"
    export REPO_ROOT
    export SCHEMA_FILE
    export VERSION_FILE
}

# Returns 0 if the openclaw binary is on PATH, 1 otherwise.
openclaw_available() {
    command -v openclaw >/dev/null 2>&1
}

@test "version pin file exists and is non-empty" {
    # The pin is the ground truth: every other test in this file
    # depends on it. If the pin is missing, the drift story is
    # broken.
    [ -f "${VERSION_FILE}" ]
    [ -s "${VERSION_FILE}" ]
    # Pin should be a plain version string like '2026.6.8' —
    # i.e. a sequence of digits and dots, no whitespace, no
    # trailing newline beyond the file terminator.
    run grep -E '^[0-9]+(\.[0-9]+)+$' "${VERSION_FILE}"
    [ "$status" -eq 0 ]
}

@test "pinned version matches installed binary" {
    # Read the pin, run `openclaw --version`, assert prefix match.
    # The binary's --version output includes the commit hash, e.g.
    # 'OpenClaw 2026.6.8 (844f405)'. We accept the version prefix.
    if ! openclaw_available; then
        skip "openclaw binary not on PATH"
    fi
    pinned="$(tr -d '[:space:]' <"${VERSION_FILE}")"
    [ -n "${pinned}" ]
    run openclaw --version
    [ "$status" -eq 0 ]
    # Output format varies between versions; we just need the
    # pinned string to appear as a token.
    [[ "${output}" == *"${pinned}"* ]]
}

@test "binary schema dump exists and is non-empty" {
    # Sanity check: if `openclaw config schema` is broken or
    # empty, none of the binary-side comparisons work. This is
    # the precondition for the rest of this file.
    if ! openclaw_available; then
        skip "openclaw binary not on PATH"
    fi
    DUMP="$(mktemp)"
    trap "rm -f '${DUMP}'" RETURN
    openclaw config schema >"${DUMP}" 2>/dev/null
    [ -s "${DUMP}" ]
    # Must be at least 100 lines — guards against a future binary
    # that returns an empty / stub schema.
    run wc -l <"${DUMP}"
    [ "${status}" -eq 0 ]
    [ "${output}" -ge 100 ]
}

@test "agent-config schema is not just the binary dump" {
    # The known failure mode we are guarding against: a future
    # PR runs `openclaw config schema > schemas/agent-config.schema.json`
    # and commits it, replacing our hand-written schema with
    # whatever the binary's accepted config shape is. The two
    # are different things (the binary's accepted shape is the
    # whole `~/.openclaw/config.json`; ours is the per-agent
    # config). If they are byte-identical, something has gone
    # wrong.
    if ! openclaw_available; then
        skip "openclaw binary not on PATH"
    fi
    DUMP="$(mktemp)"
    trap "rm -f '${DUMP}'" RETURN
    openclaw config schema >"${DUMP}" 2>/dev/null
    [ -s "${DUMP}" ]
    # The two files must differ. We compare normalized JSON
    # because the binary dump might be reformatted; a naive
    # `cmp` would catch a literal copy, but `jq -S` (sorted keys,
    # compact form) catches both literal copy and a `jq .` round-
    # trip.
    if cmp -s "${SCHEMA_FILE}" "${DUMP}"; then
        echo "FAIL: committed schema is byte-identical to binary dump"
        return 1
    fi
    # Also check normalized form, since a future script might
    # `jq .` the dump before writing it.
    norm_schema="$(jq -S -c . "${SCHEMA_FILE}")"
    norm_dump="$(jq -S -c . "${DUMP}")"
    if [ "${norm_schema}" = "${norm_dump}" ]; then
        echo "FAIL: committed schema normalizes to the binary dump"
        return 1
    fi
}

@test "additionalProperties: false survives any future refresh" {
    # additionalProperties:false is the line that makes this
    # schema strict. If a future PR flips it to true, or removes
    # it, agents in production start accepting typo'd fields
    # (e.g. `hanndle: @foo`) without complaint. The drift story
    # we want is: this value is locked.
    #
    # We assert both the root and the heartbeat.additionalProperties
    # (the only nested object in the schema) are explicitly false.
    run jq -e '
        .additionalProperties == false
        and .properties.heartbeat.additionalProperties == false
    ' "${SCHEMA_FILE}"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "handle pattern still lowercases + hyphenates" {
    # The whole point of `handle` is that it's a stable
    # lowercase Discord @mention. If a future PR relaxes the
    # pattern to allow uppercase, every consumer that does
    # case-sensitive matching (handle -> file path mapping,
    # log greps) silently starts working for the wrong reasons.
    # This test catches silent pattern relaxation.
    run jq -e '.properties.handle.pattern == "^@[a-z0-9][a-z0-9-]{1,62}$"' "${SCHEMA_FILE}"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "handle_id pattern still enforces UUID v4 variant nibble" {
    # Same story for handle_id. If a future PR widens the
    # variant nibble from [89ab] to [a-f0-9], the lockfile
    # key stops being a real UUID v4 — which breaks any
    # downstream tool that assumes the format.
    run jq -e '
        .properties.handle_id.pattern ==
        "^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$"
    ' "${SCHEMA_FILE}"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "max_bridge_depth enum is still {0, 1}" {
    # The v1 single-bridge guarantee. If a future PR adds
    # 2 or 3 to the enum, the v1 contract becomes a lie.
    run jq -e '.properties.max_bridge_depth.enum == [0, 1]' "${SCHEMA_FILE}"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "role enum is still {executor, advisor}" {
    # The dispatch table downstream branches on this enum.
    # A new value (e.g. 'observer') would break dispatch
    # silently.
    run jq -e '.properties.role.enum == ["executor", "advisor"]' "${SCHEMA_FILE}"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "required[] still lists the v1 contract bindings" {
    # If a future PR drops any of these from required[], agents
    # in production start losing their contract bindings on
    # the next deploy — schema_version, handle, handle_id,
    # contract_version, capabilities.
    run jq -e '
        (.required | sort) ==
        (["capabilities", "contract_version", "handle", "handle_id", "schema_version"] | sort)
    ' "${SCHEMA_FILE}"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "capabilities still requires minItems: 1" {
    # Without minItems, an empty capabilities array would
    # validate — and the dispatch table would then have
    # nothing to bind to, silently dropping the agent.
    run jq -e '.properties.capabilities.minItems == 1' "${SCHEMA_FILE}"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}