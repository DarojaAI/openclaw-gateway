#!/usr/bin/env bats
#
# tests/bridge-syntax.bats
#
# BATS tests for scripts/bridge-syntax.py and scripts/bridge-syntax.sh.
#
# Tests bridge syntax parsing (@A ask @B <question>), agent lookup,
# and error handling for unknown agents, missing lockfile, and
# malformed syntax.

setup() {
	REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	PYTHON_SCRIPT="${REPO_ROOT}/scripts/bridge-syntax.py"
	SHELL_WRAPPER="${REPO_ROOT}/scripts/bridge-syntax.sh"
	LOCKFILE="${REPO_ROOT}/config/agents.lock.toml"
	export REPO_ROOT PYTHON_SCRIPT SHELL_WRAPPER LOCKFILE

	# Create a temporary lockfile for tests that need isolation
	TMPDIR="${BATS_TMPDIR}/bridge-syntax-$$"
	mkdir -p "$TMPDIR"
	# Copy the real lockfile for positive tests
	cp "$LOCKFILE" "${TMPDIR}/agents.lock.toml"
	TMP_LOCKFILE="${TMPDIR}/agents.lock.toml"
	export TMPDIR TMP_LOCKFILE
}

teardown() {
	rm -rf "$TMPDIR"
}

# ---- Valid bridge syntax ----

@test "valid bridge syntax produces JSON routing decision" {
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed ask @darojaai-architect what is the architecture?" \
		"$LOCKFILE"
	[ "$status" -eq 0 ]
	# Output should be valid JSON
	echo "$output" | python3 -m json.tool > /dev/null
	# Check source agent
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['source_agent']['handle'] == '@linux-desktop-seed'
assert d['source_agent']['slug'] == 'linux-desktop-seed'
"
	# Check target agent
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['target_agent']['handle'] == '@darojaai-architect'
assert d['target_agent']['slug'] == 'darojaai-architect'
"
	# Check question
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['question'] == 'what is the architecture?'
"
	# Check bridge_syntax
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['bridge_syntax'] == '@linux-desktop-seed ask @darojaai-architect what is the architecture?'
"
}

@test "valid bridge syntax via shell wrapper" {
	run bash "$SHELL_WRAPPER" \
		"@linux-desktop-seed ask @darojaai-architect what is the architecture?" \
		"$LOCKFILE"
	[ "$status" -eq 0 ]
	echo "$output" | python3 -m json.tool > /dev/null
}

@test "bridge syntax with multi-word question" {
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed ask @darojaai-architect please describe the full deployment pipeline and how it works" \
		"$LOCKFILE"
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['question'] == 'please describe the full deployment pipeline and how it works'
"
}

@test "bridge syntax with special characters in question" {
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed ask @darojaai-architect what about user@example.com and https://example.com?" \
		"$LOCKFILE"
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'user@example.com' in d['question']
assert 'https://example.com' in d['question']
"
}

# ---- Unknown source agent ----

@test "unknown source agent returns error" {
	run python3 "$PYTHON_SCRIPT" \
		"@unknown-agent ask @darojaai-architect hello" \
		"$LOCKFILE"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "unknown agent"
	echo "$output" | grep -q "@unknown-agent"
}

# ---- Unknown target agent ----

@test "unknown target agent returns error" {
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed ask @unknown-agent hello" \
		"$LOCKFILE"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "unknown agent"
	echo "$output" | grep -q "@unknown-agent"
}

# ---- Missing lockfile ----

@test "missing lockfile returns error" {
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed ask @darojaai-architect hello" \
		"/tmp/nonexistent-lockfile.toml"
	[ "$status" -eq 2 ]
	echo "$output" | grep -q "lockfile not found or empty"
}

# ---- Malformed syntax ----

@test "malformed syntax without @ returns error" {
	run python3 "$PYTHON_SCRIPT" \
		"hello world" \
		"$LOCKFILE"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "malformed bridge syntax"
}

@test "malformed syntax missing ask keyword returns error" {
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed to @darojaai-architect hello" \
		"$LOCKFILE"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "malformed bridge syntax"
}

@test "malformed syntax missing question returns error" {
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed ask @darojaai-architect" \
		"$LOCKFILE"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "malformed bridge syntax"
}

@test "malformed syntax with only source returns error" {
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed" \
		"$LOCKFILE"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "malformed bridge syntax"
}

# ---- Empty / no arguments ----

@test "no arguments returns usage error" {
	run python3 "$PYTHON_SCRIPT"
	# argparse exits 2 on missing required argument
	[ "$status" -eq 2 ]
	echo "$output" | grep -qiE "(usage|error)"
}

@test "no arguments returns usage error via shell wrapper" {
	run bash "$SHELL_WRAPPER"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "Usage"
}

# ---- Multiple agents in message (picks first) ----

@test "multiple agents in message picks first bridge syntax" {
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed ask @darojaai-architect hello and @mcp-tooling ask @darojaai-architect goodbye" \
		"$LOCKFILE"
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# Should pick the first bridge syntax
assert d['source_agent']['handle'] == '@linux-desktop-seed'
assert d['target_agent']['handle'] == '@darojaai-architect'
"
}

# ---- Edge cases ----

@test "whitespace around message is handled" {
	run python3 "$PYTHON_SCRIPT" \
		"  @linux-desktop-seed ask @darojaai-architect hello  " \
		"$LOCKFILE"
	[ "$status" -eq 0 ]
	echo "$output" | python3 -m json.tool > /dev/null
}

@test "agent with underscore in lockfile key but hyphen in handle resolves correctly" {
	# The lockfile has agents.darojaai_architect (underscore key)
	# but the handle is @darojaai-architect (hyphen)
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed ask @darojaai-architect hello" \
		"$LOCKFILE"
	[ "$status" -eq 0 ]
	echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['target_agent']['handle'] == '@darojaai-architect'
assert d['target_agent']['slug'] == 'darojaai-architect'
assert 'darojaai' in d['target_agent']['repo']
"
}

@test "lockfile with no agents section returns error" {
	cat > "${TMPDIR}/empty-agents.toml" << 'EOF'
schema_version = "1"
EOF
	run python3 "$PYTHON_SCRIPT" \
		"@linux-desktop-seed ask @darojaai-architect hello" \
		"${TMPDIR}/empty-agents.toml"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "unknown agent"
}
