#!/usr/bin/env bats
#
# BATS tests for scripts/openrouter-provision.py
#
# What we're guarding
# -------------------
# The provisioner is the deploy-time entry point that gives each
# agent its own OpenRouter key (master/provisioning key + N child
# keys with monthly limits, see
# docs/concepts/per-agent-openrouter-keys.md). If it:
#   - silently fails to send the right body, the seed's
#     configure-openclaw-agent.sh will write a blank key into
#     auth-profiles.json and the gateway starts returning 401s.
#   - creates duplicate keys (because it does not check label),
#     agents will get a different key on every deploy and the
#     per-agent attribution in /cost-report will break.
#   - swallows non-2xx responses, a misconfigured provisioning
#     key (or a quota / outage) will look like success.
#   - leaks the provisioning key on stderr, we have a fresh
#     incident on our hands.
#
# The test surface is the CLI subcommands (provision, list, sync,
# info, revoke). We point the script at a tiny mock HTTP server
# (tests/helpers/mock-openrouter.sh) that serves canned responses
# from a per-test fixtures directory, so every test is hermetic
# and the suite is independent of the network.
#
# Conventions
# -----------
# - Each test gets a fresh fixtures dir under BATS_TEST_TMPDIR and
#   a fresh mock server on a unique port. teardown() kills the
#   server so the next test starts clean.
# - Mock fixtures are named <METHOD>_<PATH_UNDERSCORED>.json and
#   <METHOD>_<PATH_UNDERSCORED>.status. The mock server records
#   every request into requests.log and every DELETE into
#   delete_calls.log so tests can assert on call shape.
# - We never put a real provisioning key in the environment. The
#   tests set OPENROUTER_PROVISIONING_KEY to a clearly-fake value
#   (e.g. "sk-or-v1-test-fake") so a stray echo can never leak a
#   live secret.

setup() {
	REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	SCRIPT="$REPO_ROOT/scripts/openrouter-provision.py"
	MOCK="$REPO_ROOT/tests/helpers/mock-openrouter.sh"

	BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
	export BATS_TEST_TMPDIR
	FIXTURES="$BATS_TEST_TMPDIR/fixtures"
	mkdir -p "$FIXTURES"

	# Pick a free-ish port. bats 1.2 doesn't have a port helper, so
	# we ask the kernel for one and use it. If it's busy the mock
	# script will refuse to start and the test will fail with a
	# clear message rather than a confusing connection error.
	# We add a per-test offset on top of the PID-derived base to
	# avoid collisions when tests run in parallel.
	_base=$(( ($$ * 17) % 10000 + 18000 ))
	export MOCK_PORT="$_base"
	export MOCK_FIXTURES_DIR="$FIXTURES"
	export OPENROUTER_PROVISIONING_KEY="sk-or-v1-test-fake-master-key-do-not-use"

	# Stage a default list-keys response so list_keys() always
	# succeeds. Individual tests can override this.
	stage_list_response_empty

	# Start the mock server in the background. The mock script
	# prints the bound port to stdout; we read it via the file it
	# writes (we put the pid in a file we control).
	MOCK_PID_FILE="$BATS_TEST_TMPDIR/mock.pid"
	MOCK_STDOUT="$BATS_TEST_TMPDIR/mock.stdout"
	"$MOCK" "$MOCK_PORT" >"$MOCK_STDOUT" 2>"$BATS_TEST_TMPDIR/mock.stderr" &
	echo $! >"$MOCK_PID_FILE"

	# Wait for the mock to bind. We retry /dev/tcp until it
	# accepts; the mock script's port-echo on stdout is the
	# signal that bind succeeded.
	for _i in $(seq 1 50); do
		if (echo > "/dev/tcp/127.0.0.1/$MOCK_PORT") 2>/dev/null; then
			break
		fi
		sleep 0.1
	done

	export OPENROUTER_API_BASE="http://127.0.0.1:$MOCK_PORT/api/v1"
}

teardown() {
	if [ -n "${MOCK_PID_FILE:-}" ] && [ -f "$MOCK_PID_FILE" ]; then
		local pid
		pid="$(cat "$MOCK_PID_FILE" 2>/dev/null || true)"
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
		fi
	fi
	rm -rf "${BATS_TEST_TMPDIR:-/dev/null}" 2>/dev/null || true
}

# ── fixture helpers ───────────────────────────────────────────────
#
# Each helper writes the right pair of <body> + <status> files for
# one canned response. Tests can call multiple helpers to stage the
# call sequence they expect (e.g. provision needs GET /keys first
# to check for an existing label, then POST /keys to create).

stage_list_response_empty() {
	cat >"$FIXTURES/GET__api_v1_keys.json" <<'JSON'
{"data":[]}
JSON
	echo "200" >"$FIXTURES/GET__api_v1_keys.status"
}

stage_list_response_with() {
	# stage_list_response_with "<hash>" "<label>" <limit> <reset> <usage_monthly>
	local hash="$1"
	local label="$2"
	local limit="$3"
	local reset="$4"
	local usage_monthly="$5"
	cat >"$FIXTURES/GET__api_v1_keys.json" <<JSON
{"data":[{"hash":"$hash","label":"$label","limit":$limit,"limit_reset":"$reset","usage":0.0,"usage_monthly":$usage_monthly}]}
JSON
	echo "200" >"$FIXTURES/GET__api_v1_keys.status"
}

stage_create_response() {
	# stage_create_response "<key-string>" "<label>" <limit> <reset>
	local key="$1"
	local label="$2"
	local limit="$3"
	local reset="$4"
	cat >"$FIXTURES/POST__api_v1_keys.json" <<JSON
{"data":{"key":"$key","label":"$label","limit":$limit,"limit_reset":"$reset","usage":0.0,"usage_monthly":0.0,"include_byok_in_limit":true,"created_at":"2026-06-17T00:00:00Z"}}
JSON
	echo "200" >"$FIXTURES/POST__api_v1_keys.status"
}

stage_create_error() {
	# stage_create_error <status> "<body>"
	local status="$1"
	local body="$2"
	printf '%s' "$body" >"$FIXTURES/POST__api_v1_keys.json"
	echo "$status" >"$FIXTURES/POST__api_v1_keys.status"
}

stage_key_info() {
	# stage_key_info <limit> <limit_remaining> <usage_monthly>
	local limit="$1"
	local limit_remaining="$2"
	local usage_monthly="$3"
	cat >"$FIXTURES/GET__api_v1_key.json" <<JSON
{"data":{"label":"bond_nexus","limit":$limit,"limit_remaining":$limit_remaining,"usage_monthly":$usage_monthly,"include_byok_in_limit":true}}
JSON
	echo "200" >"$FIXTURES/GET__api_v1_key.status"
}

assert_requests_log_contains() {
	# assert_requests_log_contains "<METHOD> <PATH>"
	grep -F -- "$1" "$FIXTURES/requests.log" >/dev/null || {
		echo "expected request log to contain: $1" >&2
		echo "actual requests.log:" >&2
		cat "$FIXTURES/requests.log" >&2
		return 1
	}
}

# ── provision ─────────────────────────────────────────────────────

@test "provision: creates a key, prints it on stdout, returns 0" {
	stage_create_response "sk-or-v1-CHILD-AAA" "bond_nexus" 10.0 monthly
	run python3 "$SCRIPT" provision --agent bond_nexus
	[ "$status" -eq 0 ]
	# Output is a single JSON line containing the key string. The
	# caller (the seed) parses this with jq to write the value
	# into auth-profiles.json.
	echo "$output" | grep -q '"sk-or-v1-CHILD-AAA"'
	echo "$output" | grep -q '"label": "bond_nexus"'
	# We should have called list (idempotency check) THEN post.
	assert_requests_log_contains "GET /api/v1/keys"
	assert_requests_log_contains "POST /api/v1/keys"
}

@test "provision: with no provisioning key in env exits non-zero with clear message" {
	unset OPENROUTER_PROVISIONING_KEY
	run python3 "$SCRIPT" provision --agent bond_nexus
	[ "$status" -ne 0 ]
	echo "$output" | grep -q "OPENROUTER_PROVISIONING_KEY"
	# And the request log is empty — the script refused before
	# touching the network.
	[ ! -s "$FIXTURES/requests.log" ]
}

@test "provision: skips when a key with the same label already exists (no duplicate create)" {
	# Pre-existing key in the list response.
	stage_list_response_with "hash-existing" "bond_nexus" 10.0 monthly 1.5
	# If the script DID try to POST, it would hit this fixture and
	# get a 500. The point of the test is that POST is NEVER
	# called: the list check is the idempotency guard.
	stage_create_error 500 '{"error":{"message":"should not be called"}}'
	run python3 "$SCRIPT" provision --agent bond_nexus
	[ "$status" -eq 0 ]
	echo "$output" | grep -q '"existed": true'
	# GET /keys happened, POST /keys did not.
	assert_requests_log_contains "GET /api/v1/keys"
	! assert_requests_log_contains "POST /api/v1/keys"
}

@test "provision: non-2xx response surfaces body and exits non-zero" {
	stage_create_error 403 '{"error":{"message":"Invalid provisioning key"}}'
	run python3 "$SCRIPT" provision --agent bond_nexus
	[ "$status" -ne 0 ]
	echo "$output" | grep -q "Invalid provisioning key"
	echo "$output" | grep -q "403"
}

@test "provision: --dry-run prints POST body but does not call the API" {
	run python3 "$SCRIPT" provision --agent bond_nexus --limit 25 --reset weekly --dry-run
	[ "$status" -eq 0 ]
	echo "$output" | grep -q '"dry_run": true'
	echo "$output" | grep -q '"name": "bond_nexus"'
	echo "$output" | grep -q '"limit": 25'
	echo "$output" | grep -q '"limit_reset": "weekly"'
	# And the network was never touched.
	[ ! -s "$FIXTURES/requests.log" ]
}

# ── list ──────────────────────────────────────────────────────────

@test "list: returns TSV with header row" {
	stage_list_response_with "hash-1" "bond_nexus" 10.0 monthly 2.5
	stage_list_response_with "hash-2" "dev_nexus" 25.0 weekly 0.0
	# Re-write the fixture to include both keys in the data array.
	cat >"$FIXTURES/GET__api_v1_keys.json" <<'JSON'
{"data":[
  {"hash":"hash-1","label":"bond_nexus","limit":10.0,"limit_reset":"monthly","usage":12.0,"usage_monthly":2.5},
  {"hash":"hash-2","label":"dev_nexus","limit":25.0,"limit_reset":"weekly","usage":0.0,"usage_monthly":0.0}
]}
JSON
	run python3 "$SCRIPT" list
	[ "$status" -eq 0 ]
	# Header row.
	line1="$(echo "$output" | head -n 1)"
	echo "$line1" | grep -q "^hash	label	limit	limit_reset	usage_monthly$"
	# Body rows.
	echo "$output" | grep -q "hash-1	bond_nexus	10.0	monthly	2.5"
	echo "$output" | grep -q "hash-2	dev_nexus	25.0	weekly	0.0"
}

# ── info ──────────────────────────────────────────────────────────

@test "info: parses the data block and prints it as JSON" {
	stage_key_info 10.0 7.5 2.5
	run python3 "$SCRIPT" info --key "sk-or-v1-CHILD-AAA"
	[ "$status" -eq 0 ]
	echo "$output" | grep -q '"label": "bond_nexus"'
	echo "$output" | grep -q '"limit": 10'
	echo "$output" | grep -q '"usage_monthly": 2.5'
	assert_requests_log_contains "GET /api/v1/key"
}

# ── revoke ────────────────────────────────────────────────────────

@test "revoke: calls DELETE with the right hash" {
	run python3 "$SCRIPT" revoke --hash "abc123hash"
	[ "$status" -eq 0 ]
	# The path includes the hash; the mock records it into the
	# dedicated delete log so we don't have to grep the path out of
	# the requests log (which would have to be hash-aware).
	grep -F "abc123hash" "$FIXTURES/delete_calls.log" >/dev/null
}

# ── sync ──────────────────────────────────────────────────────────

@test "sync: skips agents that already have a key (no duplicate create)" {
	# bond_nexus already exists; dev_nexus is missing.
	cat >"$FIXTURES/GET__api_v1_keys.json" <<'JSON'
{"data":[{"hash":"hash-existing","label":"bond_nexus","limit":10.0,"limit_reset":"monthly","usage":1.0,"usage_monthly":0.5}]}
JSON
	# The create fixture returns a fixed key string. If the script
	# wrongly POSTs for bond_nexus, the JSONL line will reference
	# bond_nexus (label match), which is what we assert against.
	stage_create_response "sk-or-v1-NEW-DEV" "dev_nexus" 10.0 monthly
	run python3 "$SCRIPT" sync --agents "bond_nexus,dev_nexus"
	[ "$status" -eq 0 ]
	# Only one JSONL line on stdout, and it MUST be for dev_nexus.
	# If the script wrongly provisioned bond_nexus, the JSONL would
	# have a second line tagged with that label.
	bond_lines="$(echo "$output" | grep -c '"agent": "bond_nexus"' || true)"
	[ "$bond_lines" -eq 0 ]
	dev_lines="$(echo "$output" | grep -c '"agent": "dev_nexus"' || true)"
	[ "$dev_lines" -eq 1 ]
	# Exactly one POST happened, period.
	post_count="$(grep -c '^POST /api/v1/keys$' "$FIXTURES/requests.log" || true)"
	[ "$post_count" -eq 1 ]
	# Stderr should report the skip. Bats 1.2 does not capture
	# stderr separately, so we re-run with 2>&1 merged and just
	# verify the skip message is somewhere in the output.
	run bash -c "python3 '$SCRIPT' sync --agents 'bond_nexus,dev_nexus' 2>&1"
	echo "$output" | grep -q "skipped 1"
	echo "$output" | grep -q "bond_nexus"
}

@test "sync: provisions every missing agent and emits JSONL with the new key" {
	# No existing keys.
	stage_create_response "sk-or-v1-NEW-AAA" "bond_nexus" 10.0 monthly
	# For the second agent, the mock will return the same create
	# fixture — that mirrors how the test will only assert the
	# first JSONL line in detail (the second one is just "did we
	# call POST twice"). The mock overwrites the file each time.
	stage_create_response "sk-or-v1-NEW-BBB" "dev_nexus" 10.0 monthly
	run python3 "$SCRIPT" sync --agents "bond_nexus,dev_nexus"
	[ "$status" -eq 0 ]
	# Two JSONL lines, one per agent.
	echo "$output" | grep -q '"agent": "bond_nexus"'
	echo "$output" | grep -q '"agent": "dev_nexus"'
	# We should have called POST twice (once per missing agent).
	post_count="$(grep -c '^POST /api/v1/keys$' "$FIXTURES/requests.log" || true)"
	[ "$post_count" -eq 2 ]
}

@test "sync: --dry-run prints POST bodies and does not call the API" {
	run python3 "$SCRIPT" sync --agents "bond_nexus,dev_nexus" --dry-run
	[ "$status" -eq 0 ]
	# One dry-run line per agent.
	echo "$output" | grep -q '"agent-not-yet"\|"name": "bond_nexus"'
	echo "$output" | grep -q '"name": "dev_nexus"'
	# Network untouched.
	[ ! -s "$FIXTURES/requests.log" ]
}

# ── pure-function unit tests (no mock needed) ────────────────────

@test "build_create_body: emits the documented POST body shape" {
	run python3 -c "
import sys, json, importlib.util
spec = importlib.util.spec_from_file_location('op', '$SCRIPT')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.build_create_body('bond_nexus', 10.0, 'monthly')))
"
	[ "$status" -eq 0 ]
	echo "$output" | grep -q '"name": "bond_nexus"'
	echo "$output" | grep -q '"limit": 10.0'
	echo "$output" | grep -q '"limit_reset": "monthly"'
	echo "$output" | grep -q '"include_byok_in_limit": true'
}

@test "build_create_body: rejects empty agent id and non-positive limit" {
	run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('op', '$SCRIPT')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.build_create_body('', 10.0, 'monthly')
except ValueError:
    raise SystemExit(0)
raise SystemExit(2)
"
	[ "$status" -eq 0 ]
	run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('op', '$SCRIPT')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.build_create_body('bond_nexus', 0, 'monthly')
except ValueError:
    raise SystemExit(0)
raise SystemExit(2)
"
	[ "$status" -eq 0 ]
	# And a valid call still succeeds.
	run python3 -c "
import importlib.util, json
spec = importlib.util.spec_from_file_location('op', '$SCRIPT')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.build_create_body('bond_nexus', 10.0, 'monthly')))
"
	[ "$status" -eq 0 ]
	echo "$output" | grep -q '"name": "bond_nexus"'
}
