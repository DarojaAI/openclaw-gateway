#!/usr/bin/env bats
#
# End-to-end semantic validation tests for schemas/agent-config.schema.json.
#
# Purpose
# -------
# `tests/agent-config-schema.bats` proves the schema has the right
# SHAPE (draft-07, const, enums, additionalProperties). This file
# proves the schema actually REJECTS bad documents — i.e. the
# patterns, enums, minItems, and additionalProperties:false all
# fire under jsonschema's validator. Structural tests can pass on
# a schema that declares a pattern but doesn't wire it into
# `properties.handle`; semantic tests fail loudly if any rule is
# disconnected from its property.
#
# What we guard
# -------------
#   - handle_id UUID v4 pattern (variant nibble must be [89ab])
#   - max_bridge_depth enum {0, 1} — v1 single-bridge guarantee
#   - role enum {executor, advisor}
#   - capabilities minItems:1 and lowercase pattern
#   - allowed_channels snowflake pattern (17-20 digits)
#   - additionalProperties:false catches stray keys
#   - required[] catch missing handle_id
#
# Conventions
# -----------
#   - validate_yaml <body> is a shell helper that runs a python
#     validator over a YAML body. It exits 0 on success, 1 on a
#     jsonschema.ValidationError, and prints a one-line summary
#     we can grep for assertions.
#   - The Python validator is written to a tempfile via mktemp
#     in setup() once per test, so we don't pay the fork cost 10x.
#   - We call validate_yaml directly (not via bash -c) so the
#     function inherits the setup() shell's $VALIDATOR / $SCHEMA_FILE
#     without needing extra exports.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCHEMA_FILE="${REPO_ROOT}/schemas/agent-config.schema.json"
    EXAMPLE_FILE="${REPO_ROOT}/config/openclaw-agent-config.example.yaml"
    export REPO_ROOT
    export SCHEMA_FILE
    export EXAMPLE_FILE

    # Per-test python validator. Written via mktemp so the test
    # is robust to the $BATS_TMPDIR variable name across bats
    # versions (1.2 uses BATS_TMPDIR; 1.4+ uses BATS_TEST_TMPDIR;
    # mktemp just works).
    VALIDATOR="$(mktemp -t validate.XXXXXX.py)"
    cat >"${VALIDATOR}" <<'PYEOF'
import json, sys, yaml, os

with open(os.environ["SCHEMA_FILE"]) as f:
    schema = json.load(f)

body = sys.stdin.read()
try:
    doc = yaml.safe_load(body)
except yaml.YAMLError as e:
    print(f"YAML_PARSE_ERROR: {str(e).splitlines()[0]}")
    sys.exit(2)

# jsonschema requires a dict at the top level. None (empty body)
# and scalars are also validation failures — surface them as such.
try:
    import jsonschema
    jsonschema.validate(doc, schema)
    print("VALID")
    sys.exit(0)
except jsonschema.ValidationError as e:
    # The validator path is the most useful single line: it names
    # the property that failed. Tests grep for this on the
    # "missing handle_id" case.
    path = "/".join(str(x) for x in e.absolute_path) or "<root>"
    print(f"INVALID: {path}: {e.message}")
    sys.exit(1)
PYEOF

    # validate_yaml <yaml-string> -> exit 0 if valid, 1 if invalid.
    validate_yaml() {
        SCHEMA_FILE="${SCHEMA_FILE}" python3 "${VALIDATOR}" <<<"$1"
    }
}

@test "example file validates against schema" {
    # Feed the canonical example through the validator. This is the
    # smoke test: if the example is broken, every consumer sees a
    # broken example first.
    run env SCHEMA_FILE="${SCHEMA_FILE}" python3 "${VALIDATOR}" <"${EXAMPLE_FILE}"
    [ "$status" -eq 0 ]
    [ "$output" = "VALID" ]
}

@test "missing handle_id is rejected" {
    body='
schema_version: "1"
handle: "@good"
contract_version: "v1"
capabilities:
  - vm-provision
'
    run validate_yaml "$body"
    [ "$status" -eq 1 ]
    # The error must mention the missing field by name. A bare
    # "INVALID: <root>: ..." would mean we lost the property path.
    [[ "$output" == *"handle_id"* ]]
}

@test "additional properties are rejected" {
    body='
schema_version: "1"
handle: "@good"
handle_id: "f47ac10b-58cc-4372-a567-0e02b2c3d479"
contract_version: "v1"
capabilities:
  - vm-provision
unknown_field: foo
'
    run validate_yaml "$body"
    [ "$status" -eq 1 ]
    # The validator path should include the unknown field name.
    [[ "$output" == *"unknown_field"* ]] || [[ "$output" == *"Additional properties"* ]]
}

@test "empty capabilities array is rejected" {
    body='
schema_version: "1"
handle: "@good"
handle_id: "f47ac10b-58cc-4372-a567-0e02b2c3d479"
contract_version: "v1"
capabilities: []
'
    run validate_yaml "$body"
    [ "$status" -eq 1 ]
    # minItems:1 error message mentions "minItems" or "non-empty".
    [[ "$output" == *"capabilities"* ]] || [[ "$output" == *"minItems"* ]]
}

@test "handle_id with wrong UUID variant nibble is rejected" {
    # Variant nibble is the first char of group 4. Valid values
    # are 8, 9, a, b (RFC-4122). Here it's c — a hex digit, but
    # one of the reserved-for-future-use nibbles. The schema's
    # pattern is ^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-...$
    # so c in that slot must fail.
    body='
schema_version: "1"
handle: "@good"
handle_id: "f47ac10b-58cc-4372-c567-0e02b2c3d479"
contract_version: "v1"
capabilities:
  - vm-provision
'
    run validate_yaml "$body"
    [ "$status" -eq 1 ]
    [[ "$output" == *"handle_id"* ]]
}

@test "max_bridge_depth=2 is rejected" {
    body='
schema_version: "1"
handle: "@good"
handle_id: "f47ac10b-58cc-4372-a567-0e02b2c3d479"
contract_version: "v1"
capabilities:
  - vm-provision
max_bridge_depth: 2
'
    run validate_yaml "$body"
    [ "$status" -eq 1 ]
    [[ "$output" == *"max_bridge_depth"* ]]
}

@test "role: vibes is rejected" {
    body='
schema_version: "1"
handle: "@good"
handle_id: "f47ac10b-58cc-4372-a567-0e02b2c3d479"
contract_version: "v1"
capabilities:
  - vm-provision
role: vibes
'
    run validate_yaml "$body"
    [ "$status" -eq 1 ]
    [[ "$output" == *"role"* ]]
}

@test "capability with uppercase is rejected" {
    body='
schema_version: "1"
handle: "@good"
handle_id: "f47ac10b-58cc-4372-a567-0e02b2c3d479"
contract_version: "v1"
capabilities:
  - Bad-CAP
'
    run validate_yaml "$body"
    [ "$status" -eq 1 ]
    # The error path will be capabilities -> 0 (array index).
    [[ "$output" == *"capabilities"* ]] || [[ "$output" == *"0"* ]]
}

@test "allowed_channels with non-numeric ID is rejected" {
    body='
schema_version: "1"
handle: "@good"
handle_id: "f47ac10b-58cc-4372-a567-0e02b2c3d479"
contract_version: "v1"
capabilities:
  - vm-provision
allowed_channels:
  - "not-a-snowflake"
'
    run validate_yaml "$body"
    [ "$status" -eq 1 ]
    [[ "$output" == *"allowed_channels"* ]] || [[ "$output" == *"0"* ]]
}

@test "valid minimal config validates" {
    # Only the fields on the required[] list. If this passes, the
    # schema is genuinely accepting a minimal agent (which is the
    # baseline we promise the lockfile generator).
    body='
schema_version: "1"
handle: "@minimal"
handle_id: "f47ac10b-58cc-4372-a567-0e02b2c3d479"
contract_version: "v1"
capabilities:
  - vm-provision
'
    run validate_yaml "$body"
    [ "$status" -eq 0 ]
    [ "$output" = "VALID" ]
}