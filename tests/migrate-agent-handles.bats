#!/usr/bin/env bats
#
# tests/migrate-agent-handles.bats
#
# BATS tests for scripts/migrate-agent-handles.py.
# Validates migration report generation, handle detection,
# and error handling for invalid handles.

setup() {
	REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	MIGRATOR="${REPO_ROOT}/scripts/migrate-agent-handles.py"
	export REPO_ROOT MIGRATOR

	# Create a temp directory with agent subdirs
	TMPDIR="$(mktemp -d)"
	export TMPDIR

	# Clean up on teardown
	teardown() {
		rm -rf "$TMPDIR"
	}
}

teardown() {
	rm -rf "$TMPDIR"
}

# ---- Script existence and syntax ----

@test "migrator script is parseable Python" {
	[ -f "$MIGRATOR" ]
	python3 -m py_compile "$MIGRATOR"
}

@test "migrator --help exits 0" {
	run python3 "$MIGRATOR" --help
	[ "$status" -eq 0 ]
}

# ---- Agent with handle: no migration needed ----

@test "agent with valid handle shows as configured (no migration needed)" {
	mkdir -p "$TMPDIR/agent-alpha"
	cat > "$TMPDIR/agent-alpha/agent-config.yaml" <<'EOF'
handle: "@agent-alpha"
contract_version: "v1"
role: "executor"
EOF
	run python3 "$MIGRATOR" "$TMPDIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Already configured"* ]]
	[[ "$output" == *"agent-alpha"* ]]
	[[ "$output" == *"@agent-alpha"* ]]
}

# ---- Agent without handle: migration needed ----

@test "agent without handle shows as needing migration" {
	mkdir -p "$TMPDIR/agent-beta"
	cat > "$TMPDIR/agent-beta/agent-config.yaml" <<'EOF'
contract_version: "v1"
role: "executor"
EOF
	run python3 "$MIGRATOR" "$TMPDIR"
	[ "$status" -eq 1 ]
	[[ "$output" == *"Needs migration"* ]]
	[[ "$output" == *"agent-beta"* ]]
	[[ "$output" == *"@agent-beta"* ]]
}

@test "agent with empty handle shows as needing migration" {
	mkdir -p "$TMPDIR/agent-gamma"
	cat > "$TMPDIR/agent-gamma/agent-config.yaml" <<'EOF'
handle: ""
contract_version: "v1"
EOF
	run python3 "$MIGRATOR" "$TMPDIR"
	[ "$status" -eq 1 ]
	[[ "$output" == *"Needs migration"* ]]
	[[ "$output" == *"agent-gamma"* ]]
}

# ---- Multiple agents: report shows all ----

@test "multiple agents show all in report" {
	mkdir -p "$TMPDIR/agent-a" "$TMPDIR/agent-b" "$TMPDIR/agent-c"
	cat > "$TMPDIR/agent-a/agent-config.yaml" <<'EOF'
handle: "@agent-a"
contract_version: "v1"
EOF
	cat > "$TMPDIR/agent-b/agent-config.yaml" <<'EOF'
contract_version: "v1"
EOF
	cat > "$TMPDIR/agent-c/agent-config.yaml" <<'EOF'
handle: "@agent-c"
contract_version: "v1"
EOF
	run python3 "$MIGRATOR" "$TMPDIR"
	[ "$status" -eq 1 ]
	[[ "$output" == *"agent-a"* ]]
	[[ "$output" == *"agent-b"* ]]
	[[ "$output" == *"agent-c"* ]]
	[[ "$output" == *"Already configured"* ]]
	[[ "$output" == *"Needs migration"* ]]
}

# ---- Invalid handle format: error reported ----

@test "invalid handle format shows as invalid" {
	mkdir -p "$TMPDIR/agent-d"
	cat > "$TMPDIR/agent-d/agent-config.yaml" <<'EOF'
handle: "@BadHandle"
contract_version: "v1"
EOF
	run python3 "$MIGRATOR" "$TMPDIR"
	[ "$status" -eq 1 ]
	[[ "$output" == *"Invalid"* ]]
	[[ "$output" == *"agent-d"* ]]
}

@test "handle without @ shows as invalid" {
	mkdir -p "$TMPDIR/agent-e"
	cat > "$TMPDIR/agent-e/agent-config.yaml" <<'EOF'
handle: "no-at-sign"
contract_version: "v1"
EOF
	run python3 "$MIGRATOR" "$TMPDIR"
	[ "$status" -eq 1 ]
	[[ "$output" == *"Invalid"* ]]
}

@test "handle with leading dot shows as invalid" {
	mkdir -p "$TMPDIR/agent-f"
	cat > "$TMPDIR/agent-f/agent-config.yaml" <<'EOF'
handle: "@.bad"
contract_version: "v1"
EOF
	run python3 "$MIGRATOR" "$TMPDIR"
	[ "$status" -eq 1 ]
	[[ "$output" == *"Invalid"* ]]
}

# ---- Directory not found: exit 2 ----

@test "migrator exits 2 on missing directory" {
	run python3 "$MIGRATOR" "/tmp/nonexistent-dir-$$-$RANDOM"
	[ "$status" -eq 2 ]
	[[ "$output" == *"not found"* ]]
}

# ---- No agent dirs: report shows 0 agents ----

@test "empty directory shows 0 agents scanned" {
	mkdir -p "$TMPDIR/empty"
	run python3 "$MIGRATOR" "$TMPDIR/empty"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Total: 0 agent(s) scanned"* ]]
}

# ---- JSON output mode ----

@test "migrator --json outputs valid JSON" {
	mkdir -p "$TMPDIR/agent-json"
	cat > "$TMPDIR/agent-json/agent-config.yaml" <<'EOF'
handle: "@agent-json"
contract_version: "v1"
EOF
	run python3 "$MIGRATOR" --json "$TMPDIR"
	[ "$status" -eq 0 ]
	# Verify it's valid JSON
	run python3 -c "import json; json.loads('''$output''')"
	[ "$status" -eq 0 ]
}

# ---- Agent dir without config file: needs migration ----

@test "agent dir without agent-config.yaml needs migration" {
	mkdir -p "$TMPDIR/agent-noconfig"
	run python3 "$MIGRATOR" "$TMPDIR"
	[ "$status" -eq 1 ]
	[[ "$output" == *"Needs migration"* ]]
	[[ "$output" == *"agent-noconfig"* ]]
}

# ---- Handle suggestions are correct format ----

@test "suggested handle for agent with underscores uses dashes" {
	mkdir -p "$TMPDIR/agent_with_underscores"
	run python3 "$MIGRATOR" "$TMPDIR"
	[ "$status" -eq 1 ]
	[[ "$output" == *"@agent-with-underscores"* ]]
}

@test "suggested handle for agent with spaces uses dashes" {
	mkdir -p "$TMPDIR/agent with spaces"
	run python3 "$MIGRATOR" "$TMPDIR"
	[ "$status" -eq 1 ]
	[[ "$output" == *"@agent-with-spaces"* ]]
}
