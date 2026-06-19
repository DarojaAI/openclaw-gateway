#!/usr/bin/env bats
#
# tests/openclaw-defaults.bats
#
# Schema and structure tests for config/openclaw-defaults.json, the
# gateway's canonical OpenClaw config baseline (L3b layer).
#
# Why this test file exists
# --------------------------
# The seed's CI workflow (linux-desktop-seed/.github/workflows/
# data-contract-validation.yml) USED to validate this file via
# schemas/openclaw-config.schema.json, but the file was moved to
# this repo (L3b) per AGENTS.md's layering rules. The seed's CI
# now skips the check ("not present") and the gateway's own
# validate.yml only does a JSON syntax check, not a schema check.
#
# That gap meant a typo in openclaw-defaults.json would land on
# main without being caught until the runtime gateway tried to
# load the config. This test file is the local guardrail: it
# fetches the schema from the seed repo's published location on
# the same Git ref and asserts the defaults file validates.
#
# The skill-workshop approval policy is checked separately
# because it is the most recent explicit change and the regression
# we want to catch: a future edit that removes the override (or
# changes it back to the default "pending") re-introduces the
# "Plugin approval unavailable" failure that broke agent-initiated
# skill_workshop apply/reject/quarantine.

setup() {
	REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DEFAULTS_FILE="$REPO_ROOT/config/openclaw-defaults.json"
	export DEFAULTS_FILE
}

@test "openclaw-defaults.json is valid JSON" {
	run python3 -c "import json; json.load(open('$DEFAULTS_FILE'))"
	[ "$status" -eq 0 ]
}

@test "openclaw-defaults.json validates against openclaw-config.schema.json" {
	# Pull the schema from the seed repo via the GitHub Contents
	# API with the raw media type. The unauthenticated
	# raw.githubusercontent.com URL returns 404 for this path
	# (it requires the Accept: application/vnd.github.raw header
	# or the ?token=... suffix that the API attaches), so we
	# use gh api --jq with raw output instead. The fetch is
	# intentional cheap (a single API call) so the test stays
	# fast and doesn't need a separate schema submodule.
	#
	# The seed's commit pinned in deploy.yml is the authoritative
	# schema version, but for unit tests we use main HEAD. The
	# risk of drift between this test's schema and the deployed
	# schema is the same risk that exists in any cross-repo
	# schema check; the seed's own CI guards the deployed version.
	#
	# Network-less fallback: if `gh` is unavailable or the API
	# call fails, the test is skipped (not failed) so offline
	# development isn't blocked. The schema is enforced in CI
	# where network and gh auth are guaranteed.
	if ! command -v gh >/dev/null 2>&1; then
		skip "gh CLI not available; skipping schema validation"
	fi
	schema_tmp="$(mktemp)"
	if ! gh api 'repos/DarojaAI/linux-desktop-seed/contents/schemas/openclaw-config.schema.json' \
		-H 'Accept: application/vnd.github.raw' \
		--jq '.' >"$schema_tmp" 2>/dev/null; then
		rm -f "$schema_tmp"
		skip "could not fetch schema from seed repo; skipping (CI will enforce)"
	fi
	run python3 -c "
import json, sys
from jsonschema import validate, ValidationError, Draft7Validator
with open('$schema_tmp') as f:
    schema = json.load(f)
with open('$DEFAULTS_FILE') as f:
    data = json.load(f)
Draft7Validator.check_schema(schema)
try:
    validate(instance=data, schema=schema)
except ValidationError as e:
    print('ValidationError: ' + e.message, file=sys.stderr)
    sys.exit(1)
"
	rm -f "$schema_tmp"
	[ "$status" -eq 0 ]
}

@test "skills.workshop.approvalPolicy is set to 'auto'" {
	# Regression guard: the agent-initiated skill_workshop
	# apply/reject/quarantine flow requires approvalPolicy='auto'
	# because no approval route is configured in this deployment.
	# Removing this override (or changing it to 'pending') re-
	# introduces the 'Plugin approval unavailable (no approval
	# route)' error on every skill_workshop apply call.
	run python3 -c "
import json
with open('$DEFAULTS_FILE') as f:
    c = json.load(f)
policy = c.get('skills', {}).get('workshop', {}).get('approvalPolicy')
assert policy == 'auto', f'expected skills.workshop.approvalPolicy == \"auto\", got {policy!r}'
"
	[ "$status" -eq 0 ]
}

@test "approvalPolicy value is one of the schema-allowed enum values" {
	# Schema allows only 'pending' | 'auto'. Anything else is a
	# deploy-breaking typo (the gateway rejects unknown enum values).
	run python3 -c "
import json
with open('$DEFAULTS_FILE') as f:
    c = json.load(f)
policy = c.get('skills', {}).get('workshop', {}).get('approvalPolicy')
assert policy in ('pending', 'auto'), f'unexpected approvalPolicy {policy!r}; schema allows only pending|auto'
"
	[ "$status" -eq 0 ]
}
