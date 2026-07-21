#!/usr/bin/env bats
#
# tests/discord-middleware.bats
#
# BATS tests for scripts/discord-middleware.py — the Discord message middleware
# that orchestrates bridge syntax detection, @handle routing, capability dispatch,
# channel pinning, quarantine checks, canary routing, and audit logging.

setup() {
	REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	MIDDLEWARE="${REPO_ROOT}/scripts/discord-middleware.py"
	LOCKFILE="${REPO_ROOT}/config/agents.lock.toml"
	export REPO_ROOT MIDDLEWARE LOCKFILE

	# Isolated tmpdir per test
	TMPDIR="${BATS_TMPDIR}/discord-middleware-$$"
	mkdir -p "$TMPDIR"

	# Copy real lockfile for positive tests
	cp "$LOCKFILE" "${TMPDIR}/agents.lock.toml"

	# Default audit log in tmpdir (avoids polluting real log)
	export OPENCLAW_AUDIT_LOG="${TMPDIR}/audit.log"

	TMP_LOCKFILE="${TMPDIR}/agents.lock.toml"
	export TMPDIR TMP_LOCKFILE
}

teardown() {
	rm -rf "$TMPDIR"
}

# ---------------------------------------------------------------------------
# Bridge syntax detection and routing
# ---------------------------------------------------------------------------

@test "bridge syntax: valid @A ask @B routes correctly" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"@linux-desktop-seed ask @darojaai-architect what is the architecture?","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -m json.tool > /dev/null

	# Check routing decision
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing'] is not None
assert d['routing']['source_agent']['handle'] == '@linux-desktop-seed'
assert d['routing']['target_agent']['handle'] == '@darojaai-architect'
assert d['routing']['question'] == 'what is the architecture?'
assert 'bridge_syntax' in d['steps']
"
}

@test "bridge syntax: audit log entry is written" {
	python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --audit --message \
		'{"content":"@linux-desktop-seed ask @darojaai-architect hello","channel_id":"999","author_id":"1"}' \
		> /dev/null 2>&1
	[ -f "$OPENCLAW_AUDIT_LOG" ]
	# Check audit entry contains expected fields
	grep -q '"from_agent":"linux-desktop-seed"' "$OPENCLAW_AUDIT_LOG"
	grep -q '"to_agent":"darojaai-architect"' "$OPENCLAW_AUDIT_LOG"
	grep -q '"capability":"bridge"' "$OPENCLAW_AUDIT_LOG"
	grep -q '"channel_id":"999"' "$OPENCLAW_AUDIT_LOG"
}

# ---------------------------------------------------------------------------
# @handle routing
# ---------------------------------------------------------------------------

@test "handle routing: @linux-desktop-seed resolves to correct agent" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"@linux-desktop-seed hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing'] is not None
assert d['routing']['handle'] == '@linux-desktop-seed'
assert d['routing']['slug'] == 'linux-desktop-seed'
"
}

@test "handle routing: unknown handle produces violation" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"@nonexistent-agent hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]  # dry-run: still exit 0
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing'] is None
assert len(d['violations']) > 0
assert 'unknown' in d['violations'][0]
"
}

@test "handle routing: --handle override routes to specified agent" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --handle "@darojaai-architect" --message \
		'{"content":"hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing'] is not None
assert d['routing']['slug'] == 'darojaai_architect'
"
}

# ---------------------------------------------------------------------------
# Capability dispatch
# ---------------------------------------------------------------------------

@test "capability dispatch: unknown capability falls through" {
	# If @handle doesn't match, capability dispatch tries the token as capability
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"@vm-provision hello","channel_id":"123","author_id":"456"}'
	# Should either route via capability or produce a violation
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['pipeline_version'] == '1'
"
}

# ---------------------------------------------------------------------------
# Channel pinning — dry-run (default)
# ---------------------------------------------------------------------------

@test "channel pinning dry-run: violation logged but not blocked" {
	# Create an agent with a restricted allowed_channels list
	cat > "$TMP_LOCKFILE" << 'TOML'
schema_version = "1"

[agents.test_agent]
handle = "@test-agent"
repo = "DarojaAI/test-agent"
allowed_channels = ["999999"]
dry_run = true
TOML

	run python3 "$MIDDLEWARE" --lockfile "$TMP_LOCKFILE" --channel "111111" --message \
		'{"content":"@test-agent hello","channel_id":"111111","author_id":"456"}'
	[ "$status" -eq 0 ]  # dry-run: exit 0 even with violation
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['dry_run'] == True
assert d['blocked'] == False
assert d['routing'] is not None
assert d['routing']['channel_pinning']['violation'] == True
assert d['routing']['channel_pinning']['enforced'] == False
assert len(d['violations']) > 0
"
}

# ---------------------------------------------------------------------------
# Channel pinning — enforce
# ---------------------------------------------------------------------------

@test "channel pinning enforce: violation blocks message" {
	cat > "$TMP_LOCKFILE" << 'TOML'
schema_version = "1"

[agents.test_agent]
handle = "@test-agent"
repo = "DarojaAI/test-agent"
allowed_channels = ["999999"]
dry_run = false
enforce_channel_pinning = true
TOML

	run python3 "$MIDDLEWARE" --lockfile "$TMP_LOCKFILE" --enforce --channel "111111" --message \
		'{"content":"@test-agent hello","channel_id":"111111","author_id":"456"}'
	[ "$status" -eq 1 ]  # enforce mode: exit 1
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['dry_run'] == False
assert d['blocked'] == True
assert 'channel pinning' in d['blocked_reason']
"
}

@test "channel pinning enforce: allowed channel passes" {
	cat > "$TMP_LOCKFILE" << 'TOML'
schema_version = "1"

[agents.test_agent]
handle = "@test-agent"
repo = "DarojaAI/test-agent"
allowed_channels = ["111111"]
dry_run = false
enforce_channel_pinning = true
TOML

	run python3 "$MIDDLEWARE" --lockfile "$TMP_LOCKFILE" --enforce --channel "111111" --message \
		'{"content":"@test-agent hello","channel_id":"111111","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] == False
assert d['routing']['channel_pinning']['violation'] == False
"
}

# ---------------------------------------------------------------------------
# Quarantine check
# ---------------------------------------------------------------------------

@test "quarantine: quarantined agent blocks message in enforce mode" {
	# Set up lockfile with one agent
	cat > "$TMP_LOCKFILE" << 'TOML'
schema_version = "1"

[agents.test_agent]
handle = "@test-agent"
repo = "DarojaAI/test-agent"
TOML

	# Create quarantine store
	cat > "${TMPDIR}/quarantine.json" << 'JSON'
{
  "quarantined_agents": {
    "test_agent": {
      "reason": "heartbeat missed",
      "quarantined_at": "2026-07-21T00:00:00+00:00",
      "expires_at": null,
      "status": "quarantined"
    }
  }
}
JSON

	run python3 "$MIDDLEWARE" --lockfile "$TMP_LOCKFILE" --enforce --message \
		'{"content":"@test-agent hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 1 ]  # blocked
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] == True
assert 'quarantined' in d['blocked_reason']
assert 'heartbeat missed' in d['blocked_reason']
"
}

@test "quarantine: quarantined agent logged in dry-run mode" {
	cat > "$TMP_LOCKFILE" << 'TOML'
schema_version = "1"

[agents.test_agent]
handle = "@test-agent"
repo = "DarojaAI/test-agent"
TOML

	cat > "${TMPDIR}/quarantine.json" << 'JSON'
{
  "quarantined_agents": {
    "test_agent": {
      "reason": "unhealthy",
      "quarantined_at": "2026-07-21T00:00:00+00:00",
      "expires_at": null,
      "status": "quarantined"
    }
  }
}
JSON

	run python3 "$MIDDLEWARE" --lockfile "$TMP_LOCKFILE" --message \
		'{"content":"@test-agent hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]  # dry-run: exit 0
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['dry_run'] == True
assert d['blocked'] == True
assert 'quarantined' in d['blocked_reason']
"
}

@test "quarantine: bridge syntax source quarantined blocks" {
	cat > "$TMP_LOCKFILE" << 'TOML'
schema_version = "1"

[agents.source_agent]
handle = "@source-agent"
repo = "DarojaAI/source-agent"

[agents.target_agent]
handle = "@target-agent"
repo = "DarojaAI/target-agent"
TOML

	cat > "${TMPDIR}/quarantine.json" << 'JSON'
{
  "quarantined_agents": {
    "source_agent": {
      "reason": "compromised",
      "quarantined_at": "2026-07-21T00:00:00+00:00",
      "expires_at": null,
      "status": "quarantined"
    }
  }
}
JSON

	run python3 "$MIDDLEWARE" --lockfile "$TMP_LOCKFILE" --enforce --message \
		'{"content":"@source-agent ask @target-agent what is up?","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 1 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['blocked'] == True
assert 'source agent' in d['blocked_reason']
assert 'quarantined' in d['blocked_reason']
"
}

# ---------------------------------------------------------------------------
# Canary routing
# ---------------------------------------------------------------------------

@test "canary routing: canary metadata present in decision" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"@linux-desktop-seed hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing'] is not None
assert 'canary' in d['routing']
assert 'is_canary' in d['routing']['canary']
assert 'canary_weight_percent' in d['routing']['canary']
"
}

@test "canary routing: bridge syntax target gets canary metadata" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"@linux-desktop-seed ask @darojaai-architect hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing'] is not None
assert 'canary' in d['routing']
"
}

# ---------------------------------------------------------------------------
# Audit log entries
# ---------------------------------------------------------------------------

@test "audit log: handle routing writes entry" {
	python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --audit --message \
		'{"content":"@linux-desktop-seed hello","channel_id":"42","author_id":"7"}' \
		> /dev/null 2>&1
	[ -f "$OPENCLAW_AUDIT_LOG" ]
	grep -q '"from_agent":"linux-desktop-seed"' "$OPENCLAW_AUDIT_LOG"
	grep -q '"capability":"handle"' "$OPENCLAW_AUDIT_LOG"
}

@test "audit log: bridge syntax writes entry" {
	python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --audit --message \
		'{"content":"@linux-desktop-seed ask @darojaai-architect review code","channel_id":"55","author_id":"8"}' \
		> /dev/null 2>&1
	[ -f "$OPENCLAW_AUDIT_LOG" ]
	grep -q '"from_agent":"linux-desktop-seed"' "$OPENCLAW_AUDIT_LOG"
	grep -q '"to_agent":"darojaai-architect"' "$OPENCLAW_AUDIT_LOG"
	grep -q '"capability":"bridge"' "$OPENCLAW_AUDIT_LOG"
}

# ---------------------------------------------------------------------------
# Missing lockfile
# ---------------------------------------------------------------------------

@test "missing lockfile produces no routing changes" {
	run python3 "$MIDDLEWARE" --lockfile "${TMPDIR}/nonexistent.toml" --message \
		'{"content":"@linux-desktop-seed hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing'] is None
assert 'registry_empty' in d['steps']
"
}

# ---------------------------------------------------------------------------
# Default dry-run mode
# ---------------------------------------------------------------------------

@test "default mode is dry-run" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"@linux-desktop-seed hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['dry_run'] == True
assert d['blocked'] == False
"
}

@test "dry-run with violations still exits 0" {
	cat > "$TMP_LOCKFILE" << 'TOML'
schema_version = "1"

[agents.test_agent]
handle = "@test-agent"
repo = "DarojaAI/test-agent"
allowed_channels = ["999999"]
dry_run = true
TOML

	run python3 "$MIDDLEWARE" --lockfile "$TMP_LOCKFILE" --channel "111111" --message \
		'{"content":"@test-agent hello","channel_id":"111111","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['dry_run'] == True
assert d['blocked'] == False
assert len(d['violations']) > 0
"
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "empty content produces no routing" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['routing'] is None
assert 'no_handles' in d['steps']
"
}

@test "no message argument and empty stdin produces error" {
	run bash -c "echo '' | python3 '$MIDDLEWARE' --lockfile '$LOCKFILE'"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "no message provided"
}

@test "malformed JSON input produces error" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message "not json"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "invalid JSON"
}

@test "pipeline version is 1" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['pipeline_version'] == '1'
"
}

@test "steps list is populated for handle routing" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"@linux-desktop-seed hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'routing' in d['steps']
assert 'canary_routing' in d['steps']
assert 'audit_log' in d['steps']
"
}

@test "steps list is populated for bridge syntax" {
	run python3 "$MIDDLEWARE" --lockfile "$LOCKFILE" --message \
		'{"content":"@linux-desktop-seed ask @darojaai-architect hello","channel_id":"123","author_id":"456"}'
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'bridge_syntax' in d['steps']
assert 'routing' in d['steps']
assert 'canary_routing' in d['steps']
assert 'audit_log' in d['steps']
"
}
