#!/usr/bin/env bats
#
# BATS tests for schemas/agent-config.schema.json
#
# What we're guarding
# -------------------
# Phase-1 deliverable for RFC issue #31 (agent-config schema +
# drift guardrail). The schema is the source of truth for the
# shape of per-agent `.openclaw/agent-config.yaml` files. If it:
#   - drifts away from draft-07, the gateway binary (which is
#     pinned to draft-07) will reject configs the schema says are
#     valid, or accept configs the schema says are invalid.
#   - drops a required field, agents in production start losing
#     their contract bindings on the next deploy.
#   - loosens a pattern (e.g. handle), rename-stable @mention
#     routing breaks.
#   - silently widens the max_bridge_depth enum past 1, the v1
#     single-bridge guarantee stops being guaranteed.
#
# Conventions
# -----------
# - We use jq for structural assertions (it's already in the
#   test image) and only invoke python+jsonschema for the
#   sample-document tests. The structural tests are
#   hermetic and run in <50ms each.
# - REPO_ROOT is computed once in setup() and used everywhere;
#   tests never `cd` out of the repo root.
# - Negative-case tests validate a small inline document via a
#   heredoc piped to python, which keeps the suite independent
#   of any extra binaries (yq, ajv, etc.).

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCHEMA_FILE="${REPO_ROOT}/schemas/agent-config.schema.json"
    export REPO_ROOT
    export SCHEMA_FILE
}

@test "schema file exists and is valid JSON" {
    [ -f "$SCHEMA_FILE" ]
    run jq empty "$SCHEMA_FILE"
    [ "$status" -eq 0 ]
}

@test "schema is JSON Schema draft-07" {
    run jq -e '."$schema" == "http://json-schema.org/draft-07/schema#"' "$SCHEMA_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "schema_version is the const '1'" {
    run jq -e '.properties.schema_version.const == "1"' "$SCHEMA_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "handle pattern rejects uppercase" {
    run python3 -c "
import json, jsonschema, sys
with open('$SCHEMA_FILE') as f:
    schema = json.load(f)
doc = {
    'schema_version': '1',
    'handle': '@BadHandle',
    'handle_id': 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'contract_version': 'v1',
    'capabilities': ['vm-provision'],
}
try:
    jsonschema.validate(doc, schema)
    print('UNEXPECTED_PASS')
    sys.exit(1)
except jsonschema.ValidationError:
    print('REJECTED_OK')
    sys.exit(0)
"
    [ "$status" -eq 0 ]
    [ "$output" = "REJECTED_OK" ]
}

@test "handle_id pattern rejects non-UUID" {
    run python3 -c "
import json, jsonschema, sys
with open('$SCHEMA_FILE') as f:
    schema = json.load(f)
doc = {
    'schema_version': '1',
    'handle': '@good',
    'handle_id': 'not-a-uuid',
    'contract_version': 'v1',
    'capabilities': ['vm-provision'],
}
try:
    jsonschema.validate(doc, schema)
    print('UNEXPECTED_PASS')
    sys.exit(1)
except jsonschema.ValidationError:
    print('REJECTED_OK')
    sys.exit(0)
"
    [ "$status" -eq 0 ]
    [ "$output" = "REJECTED_OK" ]
}

@test "max_bridge_depth enum is {0, 1}" {
    run jq -e '.properties.max_bridge_depth.enum == [0, 1]' "$SCHEMA_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "additionalProperties is false" {
    run jq -e '.additionalProperties == false' "$SCHEMA_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "role enum is {executor, advisor}" {
    run jq -e '.properties.role.enum == ["executor", "advisor"]' "$SCHEMA_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "capabilities items must match pattern" {
    run python3 -c "
import json, jsonschema, sys
with open('$SCHEMA_FILE') as f:
    schema = json.load(f)
doc = {
    'schema_version': '1',
    'handle': '@good',
    'handle_id': 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'contract_version': 'v1',
    'capabilities': ['Bad-CAP'],
}
try:
    jsonschema.validate(doc, schema)
    print('UNEXPECTED_PASS')
    sys.exit(1)
except jsonschema.ValidationError:
    print('REJECTED_OK')
    sys.exit(0)
"
    [ "$status" -eq 0 ]
    [ "$output" = "REJECTED_OK" ]
}

@test "allowed_channels pattern requires 17-20 digits" {
    # Positive case: a real Discord snowflake must validate
    run python3 -c "
import json, jsonschema, sys
with open('$SCHEMA_FILE') as f:
    schema = json.load(f)
doc = {
    'schema_version': '1',
    'handle': '@good',
    'handle_id': 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'contract_version': 'v1',
    'capabilities': ['vm-provision'],
    'allowed_channels': ['1501612164098687087'],
}
try:
    jsonschema.validate(doc, schema)
    print('ACCEPTED_OK')
    sys.exit(0)
except jsonschema.ValidationError as e:
    print('UNEXPECTED_FAIL:', e.message[:80])
    sys.exit(1)
"
    [ "$status" -eq 0 ]
    [ "$output" = "ACCEPTED_OK" ]

    # Negative case: 'abc' must be rejected
    run python3 -c "
import json, jsonschema, sys
with open('$SCHEMA_FILE') as f:
    schema = json.load(f)
doc = {
    'schema_version': '1',
    'handle': '@good',
    'handle_id': 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'contract_version': 'v1',
    'capabilities': ['vm-provision'],
    'allowed_channels': ['abc'],
}
try:
    jsonschema.validate(doc, schema)
    print('UNEXPECTED_PASS')
    sys.exit(1)
except jsonschema.ValidationError:
    print('REJECTED_OK')
    sys.exit(0)
"
    [ "$status" -eq 0 ]
    [ "$output" = "REJECTED_OK" ]
}
