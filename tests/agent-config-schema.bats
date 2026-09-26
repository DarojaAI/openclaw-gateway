#!/usr/bin/env bats
#
# tests/agent-config-schema.bats
#
# BATS tests for schemas/agent-config.schema.json plus smoke tests
# for scripts/validate-agent-config.py.
#
# 2026-09-26: the RFC-31 lockfile half (agents-lock.schema.json,
# generate-agents-lock.py) was retired with the rest of the dormant
# lockfile pipeline -- see the retirement PR for the evidence.
#
# What we guard
# -------------
# Phase-1 deliverable for RFC issue #31. The two JSON Schemas are
# the source of truth for the shape of per-agent
# `.openclaw/agent-config.yaml` files and the compiled
# `agents.lock.toml`. The two Python scripts are the validator and
# the lockfile-entry emitter. If any of these drift:
#   - the deploy action (Phase-1 sibling) will reject configs the
#     schema says are valid, or accept configs the schema says are
#     invalid.
#   - the lockfile emitter will produce malformed entries that the
#     gateway cannot parse.
#   - the heartbeat / role / capability enum guards stop firing
#     and consumers silently start accepting bad inputs.
#
# Conventions
# -----------
# - Structural schema assertions use jq (always available in the
#   test image). Sample-document and lockfile-schema assertions
#   use the canonical Python scripts written for this phase —
#   the validator exercises both the manual (stdlib-only) and
#   full (jsonschema) paths where it can.
# - REPO_ROOT, SCHEMA_FILE, VALIDATOR are computed once in setup().
# - Negative-case tests build small inline YAML / JSON bodies and
#   pipe them to the validator. This keeps the suite independent
#   of yq / ajv / PyYAML when jsonschema is missing.

setup() {
	REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	SCHEMA_FILE="${REPO_ROOT}/schemas/agent-config.schema.json"
	VALIDATOR="${REPO_ROOT}/scripts/validate-agent-config.py"
	export REPO_ROOT SCHEMA_FILE VALIDATOR
}

# ---- agent-config schema: structural assertions ----

@test "agent-config schema file exists and is valid JSON" {
	[ -f "$SCHEMA_FILE" ]
	run jq empty "$SCHEMA_FILE"
	[ "$status" -eq 0 ]
}

@test "agent-config schema is JSON Schema 2020-12" {
	run jq -e '."$schema" == "https://json-schema.org/draft/2020-12/schema"' "$SCHEMA_FILE"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "agent-config schema has additionalProperties=false" {
	run jq -e '.additionalProperties == false' "$SCHEMA_FILE"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "agent-config schema requires handle and contract_version" {
	run jq -e '(.required | sort) == ["contract_version", "handle"]' "$SCHEMA_FILE"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "agent-config schema role enum is {executor, advisor}" {
	run jq -e '.properties.role.enum == ["executor", "advisor"]' "$SCHEMA_FILE"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "agent-config schema contract_version enum is {v1}" {
	run jq -e '.properties.contract_version.enum == ["v1"]' "$SCHEMA_FILE"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "agent-config schema handle pattern is anchored and lowercase" {
	run jq -e '.properties.handle.pattern == "^@[a-z0-9]([a-z0-9._-]*[a-z0-9])?$"' "$SCHEMA_FILE"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "agent-config schema heartbeat has additionalProperties=false" {
	run jq -e '.properties.heartbeat.additionalProperties == false' "$SCHEMA_FILE"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "agent-config schema heartbeat interval_hours is 1..168" {
	run jq -e '
		.properties.heartbeat.properties.interval_hours.minimum == 1
		and .properties.heartbeat.properties.interval_hours.maximum == 168
	' "$SCHEMA_FILE"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

# ---- validator script: syntax + presence ----

@test "validator script is parseable Python" {
	[ -f "$VALIDATOR" ]
	python3 -m py_compile "$VALIDATOR"
}

@test "validator --help exits 0 and mentions --schema" {
	run python3 "$VALIDATOR" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--schema"* ]]
}

@test "validator exits 2 on missing document" {
	run python3 "$VALIDATOR" /tmp/does-not-exist-$$-$RANDOM.yaml
	[ "$status" -eq 2 ]
}

# ---- validator script: positive cases via JSON inputs ----

# Helper: write a body to a tempfile and run the validator on it.
validate_json() {
	local body="$1"
	local f
	f="$(mktemp)"
	printf '%s' "$body" >"$f"
	run python3 "$VALIDATOR" --schema "$SCHEMA_FILE" "$f"
	rm -f "$f"
}

@test "validator accepts a fully-populated agent config" {
	body='{
		"handle": "@linux-desktop-seed",
		"contract_version": "v1",
		"capabilities": ["vm-provision", "vm-decommission", "pr-stewardship"],
		"allowed_channels": ["#openclaw-ops", "ops-alerts"],
		"role": "executor",
		"skills": ["deploy-skill", "rollback-skill"],
		"heartbeat": {"enabled": true, "interval_hours": 24},
		"canary": false
	}'
	validate_json "$body"
	[ "$status" -eq 0 ]
	[ "$output" = "VALID" ]
}

@test "validator accepts a required-only agent config" {
	body='{"handle": "@minimal", "contract_version": "v1"}'
	validate_json "$body"
	[ "$status" -eq 0 ]
	[ "$output" = "VALID" ]
}

@test "validator accepts a config with only capabilities set" {
	body='{"handle": "@cap-only", "contract_version": "v1", "capabilities": ["vm-provision"]}'
	validate_json "$body"
	[ "$status" -eq 0 ]
	[ "$output" = "VALID" ]
}

@test "validator accepts a config with only allowed_channels set" {
	body='{"handle": "@ch-only", "contract_version": "v1", "allowed_channels": ["#ops"]}'
	validate_json "$body"
	[ "$status" -eq 0 ]
	[ "$output" = "VALID" ]
}

@test "validator accepts a config with only role set" {
	body='{"handle": "@role-only", "contract_version": "v1", "role": "advisor"}'
	validate_json "$body"
	[ "$status" -eq 0 ]
	[ "$output" = "VALID" ]
}

@test "validator accepts a config with only skills set" {
	body='{"handle": "@skills-only", "contract_version": "v1", "skills": ["runbook"]}'
	validate_json "$body"
	[ "$status" -eq 0 ]
	[ "$output" = "VALID" ]
}

@test "validator accepts a config with only heartbeat set" {
	body='{"handle": "@hb-only", "contract_version": "v1", "heartbeat": {"enabled": false, "interval_hours": 1}}'
	validate_json "$body"
	[ "$status" -eq 0 ]
	[ "$output" = "VALID" ]
}

@test "validator accepts a config with only canary set" {
	body='{"handle": "@canary-only", "contract_version": "v1", "canary": true}'
	validate_json "$body"
	[ "$status" -eq 0 ]
	[ "$output" = "VALID" ]
}

# ---- validator script: negative cases ----

@test "validator rejects a config missing handle" {
	body='{"contract_version": "v1"}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"handle"* ]]
}

@test "validator rejects a config missing contract_version" {
	body='{"handle": "@x"}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"contract_version"* ]]
}

@test "validator rejects a handle without @" {
	body='{"handle": "no-at", "contract_version": "v1"}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"handle"* ]]
}

@test "validator rejects a handle with uppercase" {
	body='{"handle": "@BadHandle", "contract_version": "v1"}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"handle"* ]]
}

@test "validator rejects a handle with a leading dot" {
	body='{"handle": "@.starts-with-dot", "contract_version": "v1"}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"handle"* ]]
}

@test "validator rejects a capability with uppercase" {
	body='{"handle": "@x", "contract_version": "v1", "capabilities": ["Bad-CAP"]}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"capabilities"* ]]
}

@test "validator rejects a capability with leading digit" {
	body='{"handle": "@x", "contract_version": "v1", "capabilities": ["1bad"]}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"capabilities"* ]]
}

@test "validator rejects an empty capability string" {
	body='{"handle": "@x", "contract_version": "v1", "capabilities": [""]}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"capabilities"* ]]
}

@test "validator rejects a role outside the enum" {
	body='{"handle": "@x", "contract_version": "v1", "role": "vibes"}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"role"* ]]
}

@test "validator rejects heartbeat with interval_hours=0" {
	body='{"handle": "@x", "contract_version": "v1", "heartbeat": {"enabled": true, "interval_hours": 0}}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"interval_hours"* ]]
}

@test "validator rejects heartbeat with interval_hours=169" {
	body='{"handle": "@x", "contract_version": "v1", "heartbeat": {"enabled": true, "interval_hours": 169}}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"interval_hours"* ]]
}

@test "validator rejects an unknown top-level property" {
	body='{"handle": "@x", "contract_version": "v1", "unknown_field": "oops"}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"unknown_field"* ]]
}

@test "validator rejects heartbeat with an unknown property" {
	body='{"handle": "@x", "contract_version": "v1", "heartbeat": {"enabled": true, "interval_hours": 24, "extra": true}}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"extra"* ]] || [[ "$output" == *"heartbeat"* ]]
}

@test "validator rejects duplicate capabilities" {
	body='{"handle": "@x", "contract_version": "v1", "capabilities": ["vm-provision", "vm-provision"]}'
	validate_json "$body"
	[ "$status" -eq 1 ]
	[[ "$output" == *"capabilities"* ]]
}

# ---- agents-lock schema: structural + sample document ----

# ---- emitter script ----

