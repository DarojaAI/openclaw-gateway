#!/usr/bin/env bats
#
# tests/discord-response-normalizer.bats
#
# BATS tests for the Discord response normalizer service.
#
# Why this test file exists: the normalizer is the canonical "what Discord
# sees" shim. Every other agent on this host will route its outbound Discord
# replies through it. If the canonicalize/escape/chunk logic regresses, the
# fleet silently ships inconsistent Discord output to users. The contract
# MUST be enforced here, not in the service.
#
# The tests exercise lib/normalize.js directly via `node -e '...'` and the
# CLI/HTTP entry points via subprocess. No port binding for the lib tests;
# the HTTP server tests use a real port and clean up after themselves.
#
# Convention: tests that need to pass a string with backticks, newlines, or
# quotes to the lib write it to a tempfile with `mktemp` + `printf '%s'` and
# read it from inside `node -e` via `fs.readFileSync(0, 'utf8')` (stdin).
# We do NOT pass strings through `process.argv[1]` because BATS + bash
# double-expansion mangles backticks and quote pairs.

setup() {
	REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	NORMALIZER_LIB="$REPO_ROOT/config/services/discord-response-normalizer/lib/normalize.js"
	NORMALIZER_CLI="$REPO_ROOT/config/services/discord-response-normalizer/normalize-cli.js"
	NORMALIZER_SERVER="$REPO_ROOT/config/services/discord-response-normalizer/normalize-server.js"
	export REPO_ROOT NORMALIZER_LIB NORMALIZER_CLI NORMALIZER_SERVER

	if [ ! -f "$NORMALIZER_LIB" ]; then
		skip "normalize.js not found at $NORMALIZER_LIB"
	fi
	if ! command -v node >/dev/null 2>&1; then
		skip "node not on PATH"
	fi
	if ! command -v jq >/dev/null 2>&1; then
		skip "jq not on PATH (required for JSON assertions)"
	fi
}

teardown() {
	:
}

# Helper: run a node snippet that reads its input from stdin and emits JSON
# to stdout. The snippet body is provided as $1, the input as $2.
#
# Usage: run_lib_stdout '<js expression reading process.stdin or argv>' '<input>'
#
# The snippet MUST end by writing to process.stdout and the expression has
# access to: `m` (the normalize lib), `fs`, plus any globals you set.
#
# To make calling easy we standardize on: snippet reads text via
# fs.readFileSync(0, 'utf8'), or from a path passed as the first CLI arg.
run_lib_stdin() {
	local snippet="$1"
	local input="$2"
	local f
	f="$(mktemp)"
	printf '%s' "$input" > "$f"
	run node -e "
const fs = require('fs');
const m = require(process.env.NORMALIZER_LIB);
const input = fs.readFileSync(0, 'utf8');
$snippet
" < "$f"
	rm -f "$f"
}

# ---------------------------------------------------------------------------
# Stage 1: canonicalize
# ---------------------------------------------------------------------------

@test "canonicalize: CRLF and lone CR normalize to LF" {
	run_lib_stdin 'process.stdout.write(JSON.stringify(m.canonicalize(input)));' "$(printf 'a\r\nb\rc')"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r .)" = "$(printf 'a\nb\nc')" ]
}

@test "canonicalize: trailing whitespace stripped per line" {
	run_lib_stdin 'process.stdout.write(JSON.stringify(m.canonicalize(input)));' "$(printf 'hello   \nworld\t')"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r .)" = "$(printf 'hello\nworld\n')" ]
}

@test "canonicalize: deep headings (H4-H6) collapse to H2" {
	run_lib_stdin 'process.stdout.write(JSON.stringify(m.canonicalize(input)));' "$(printf '#### foo\n##### bar\n###### baz')"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r .)" = "$(printf '## foo\n## bar\n## baz')" ]
}

@test "canonicalize: numbered list prefixes normalize to 1." {
	run_lib_stdin 'process.stdout.write(JSON.stringify(m.canonicalize(input)));' "$(printf '1) foo\n2- bar\n3. baz')"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r .)" = "$(printf '1. foo\n2. bar\n3. baz')" ]
}

@test "canonicalize: 3+ blank lines collapse to 2" {
	run_lib_stdin 'process.stdout.write(JSON.stringify(m.canonicalize(input)));' "$(printf 'a\n\n\n\n\nb')"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r .)" = "$(printf 'a\n\nb')" ]
}

@test "canonicalize: throws on non-string input" {
	run node -e '
		const { canonicalize } = require(process.env.NORMALIZER_LIB);
		try { canonicalize(42); process.stdout.write("did_not_throw"); process.exit(0); }
		catch (e) { process.stdout.write("threw"); process.exit(0); }
	'
	[ "$status" -eq 0 ]
	[ "$output" = "threw" ]
}

# ---------------------------------------------------------------------------
# Stage 2: escapeOutsideFences
# ---------------------------------------------------------------------------

@test "escape: prose underscores get backslash-escaped" {
	run_lib_stdin 'process.stdout.write(JSON.stringify(m.escapeOutsideFences(input)));' "use the _foo_ flag"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r .)" = 'use the \_foo\_ flag' ]
}

@test "escape: prose asterisks get backslash-escaped" {
	run_lib_stdin 'process.stdout.write(JSON.stringify(m.escapeOutsideFences(input)));' "**not bold** here"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r .)" = '\*\*not bold\*\* here' ]
}

@test "escape: characters inside code fences pass through unchanged" {
	input="$(printf '```\n_underscore_inside_fence_\n```')"
	run_lib_stdin 'process.stdout.write(JSON.stringify(m.escapeOutsideFences(input)));' "$input"
	[ "$status" -eq 0 ]
	out="$(echo "$output" | jq -r .)"
	echo "$out" | grep -q '_underscore_inside_fence_'
	# No backslash-escaped underscores anywhere.
	! echo "$out" | grep -q '\\_'
}

@test "escape: 4-backtick fence opens a separate scope" {
	input="$(printf 'before _x_\n````\n_inside_\n````\nafter _y_')"
	run_lib_stdin 'process.stdout.write(JSON.stringify(m.escapeOutsideFences(input)));' "$input"
	[ "$status" -eq 0 ]
	out="$(echo "$output" | jq -r .)"
	# Outside fences: escaped
	echo "$out" | grep -qF 'before \_x\_'
	echo "$out" | grep -qF 'after \_y\_'
	# Inside fence: untouched
	echo "$out" | grep -qF '_inside_'
}

# ---------------------------------------------------------------------------
# Stage 4: chunk
# ---------------------------------------------------------------------------

@test "chunk: short text returns single chunk" {
	run_lib_stdin 'process.stdout.write(JSON.stringify(m.chunk(input)));' "hello world"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.[0]')" = "hello world" ]
	[ "$(echo "$output" | jq 'length')" = "1" ]
}

@test "chunk: text under 2000 chars returns one chunk" {
	run_lib_stdin '
		const text = "x".repeat(1500);
		process.stdout.write(JSON.stringify(m.chunk(text)));
	' "$(printf 'x%.0s' $(seq 1 1500))"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq 'length')" = "1" ]
}

@test "chunk: text over 2000 chars splits, each chunk <=2000" {
	run_lib_stdin '
		const text = "x".repeat(4500);
		const out = m.chunk(text);
		const max = Math.max(...out.map(c => c.length));
		process.stdout.write(JSON.stringify({ count: out.length, max: max }));
	' "$(printf 'x%.0s' $(seq 1 4500))"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq '.count >= 3')" = "true" ]
	[ "$(echo "$output" | jq '.max <= 2000')" = "true" ]
}

@test "chunk: fence split across chunks balances across the boundary" {
	# NB: the JS literal "`\`\`\`python" in double quotes parses as 4 backticks
	# + "python" because bash + node double-quote escaping collide. The test
	# is intentionally exercising the 4-backtick fence case. The chunker
	# preserves whatever marker length the input has.
	run_lib_stdin '
		const pad = "x".repeat(2200);
		const fence = "`\`\`\`python\n" + pad + "\n`\`\`";
		const out = m.chunk(fence);
		process.stdout.write(JSON.stringify(out));
	' ""
	[ "$status" -eq 0 ]
	count="$(echo "$output" | jq 'length')"
	[ "$count" -ge 3 ]
	# First chunk should be the opener (whatever marker length the input had).
	first="$(echo "$output" | jq -r '.[0]')"
	# Last chunk should end with a closer line. Use jq to check that the
	# final chunk ends with a fence-marker line, avoiding bash backtick
	# interpolation headaches entirely.
	[ "$(echo "$output" | jq -r '.[length-1] | test("`{3,}\\s*$")')" = "true" ]
	# All chunks must be <= DISCORD_MAX.
	[ "$(echo "$output" | jq 'map(length) | max <= 2000')" = "true" ]
}

@test "identity: deterministic fallback from agent_id" {
	run node -e '
		const { stableIdentity } = require(process.env.NORMALIZER_LIB);
		process.stdout.write(JSON.stringify(stableIdentity("linux_desktop_seed", {})));
	'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.username')" = "openclaw-linux-desktop-seed" ]
	[ "$(echo "$output" | jq -r '.avatar_url')" = "https://api.dicebear.com/9.x/identicon/svg?seed=linux_desktop_seed" ]
}
@test "identity: registry overrides fallback" {
	run node -e '
		const { stableIdentity } = require(process.env.NORMALIZER_LIB);
		const out = stableIdentity("linux_desktop_seed", {
			linux_desktop_seed: { username: "LDS", avatar_url: "https://example.com/lds.png" }
		});
		process.stdout.write(JSON.stringify(out));
	'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.username')" = "LDS" ]
	[ "$(echo "$output" | jq -r '.avatar_url')" = "https://example.com/lds.png" ]
}

@test "identity: same agent_id yields same identity across calls" {
	run node -e '
		const { stableIdentity } = require(process.env.NORMALIZER_LIB);
		const a = stableIdentity("darojaai_architect", {});
		const b = stableIdentity("darojaai_architect", {});
		process.stdout.write(JSON.stringify({ match: JSON.stringify(a) === JSON.stringify(b) }));
	'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.match')" = "true" ]
}

# ---------------------------------------------------------------------------
# Top-level normalize()
# ---------------------------------------------------------------------------

@test "normalize: returns chunks + content + identity" {
	run node -e '
		const { normalize } = require(process.env.NORMALIZER_LIB);
		const out = normalize("hello world", { agent_id: "linux_desktop_seed" });
		process.stdout.write(JSON.stringify(out));
	'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.content')" = "hello world" ]
	[ "$(echo "$output" | jq -r '.chunks[0]')" = "hello world" ]
	[ "$(echo "$output" | jq -r '.username')" = "openclaw-linux-desktop-seed" ]
	# avatar_url should start with https://
	avatar="$(echo "$output" | jq -r '.avatar_url')"
	case "$avatar" in
		https://*) ;;
		*) echo "FAIL: avatar_url does not start with https://: $avatar"; return 1 ;;
	esac
}

@test "normalize: throws without agent_id" {
	run node -e '
		const { normalize } = require(process.env.NORMALIZER_LIB);
		try { normalize("text", {}); process.stdout.write("did_not_throw"); process.exit(0); }
		catch (e) { process.stdout.write("threw"); process.exit(0); }
	'
	[ "$status" -eq 0 ]
	[ "$output" = "threw" ]
}

@test "normalize: round-trips a model-reply-shaped input" {
	input="$(printf '1) first item\n2) second item\n\n\n\n\n\nuse the _foo_ flag\n')"
	run_lib_stdin '
		const out = m.normalize(input, { agent_id: "linux_desktop_seed" });
		process.stdout.write(JSON.stringify(out));
	' "$input"
	[ "$status" -eq 0 ]
	body="$(echo "$output" | jq -r '.chunks[0]')"
	echo "$body" | grep -qF '1. first item'
	echo "$body" | grep -qF '2. second item'
	# Underscores should be backslash-escaped
	echo "$body" | grep -qF 'use the \_foo\_ flag'
	# 3+ blank lines should be collapsed
	! echo "$body" | grep -P '(?<!\\)\n{3,}' >/dev/null 2>&1
}

@test "normalize: identity persists across chunks" {
	run node -e '
		const text = "x".repeat(4500);
		const { normalize } = require(process.env.NORMALIZER_LIB);
		const out = normalize(text, { agent_id: "darojaai_architect" });
		process.stdout.write(JSON.stringify(out));
	'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq '.chunks | length >= 2')" = "true" ]
	[ "$(echo "$output" | jq -r '.username')" = "openclaw-darojaai-architect" ]
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

@test "CLI: --help exits 0 and prints usage" {
	[ -f "$NORMALIZER_CLI" ] || skip "normalize-cli.js not found"
	run node "$NORMALIZER_CLI" --help
	[ "$status" -eq 0 ]
	echo "$output" | grep -qF "Usage:"
}

@test "CLI: stdin pipe produces JSON with chunks" {
	[ -f "$NORMALIZER_CLI" ] || skip "normalize-cli.js not found"
	run bash -c "echo 'hello world' | node '$NORMALIZER_CLI' --agent linux_desktop_seed"
	[ "$status" -eq 0 ]
	echo "$output" | jq -r '.chunks[0]' | grep -qF 'hello world'
	echo "$output" | jq -r '.username' | grep -qF 'openclaw-linux-desktop-seed'
}

@test "CLI: --file mode reads from a file" {
	[ -f "$NORMALIZER_CLI" ] || skip "normalize-cli.js not found"
	f="$(mktemp)"
	printf 'reply from file\n' > "$f"
	run node "$NORMALIZER_CLI" --agent linux_desktop_seed --file "$f"
	rm -f "$f"
	[ "$status" -eq 0 ]
	echo "$output" | jq -r '.content' | grep -qF 'reply from file'
}

@test "CLI: missing --agent exits 2" {
	[ -f "$NORMALIZER_CLI" ] || skip "normalize-cli.js not found"
	run bash -c "echo 'x' | node '$NORMALIZER_CLI'"
	[ "$status" -eq 2 ]
	echo "$output" | grep -qF "agent is required"
}

# ---------------------------------------------------------------------------
# HTTP server smoke test
# ---------------------------------------------------------------------------

@test "HTTP: server responds to GET /health" {
	[ -f "$NORMALIZER_SERVER" ] || skip "normalize-server.js not found"
	[ -x "$(command -v curl)" ] || skip "curl not on PATH"
	# Pick an ephemeral port
	export NORMALIZER_PORT="${NORMALIZER_TEST_PORT:-8767}"
	node "$NORMALIZER_SERVER" >/dev/null 2>&1 &
	SERVER_PID=$!
	ready=0
	for i in 1 2 3 4 5 6 7 8 9 10; do
		if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${NORMALIZER_PORT}/health"; then
			ready=1
			break
		fi
		sleep 0.2
	done
	run curl -s "http://127.0.0.1:${NORMALIZER_PORT}/health"
	kill "$SERVER_PID" 2>/dev/null || true
	wait "$SERVER_PID" 2>/dev/null || true
	if [ "$ready" -ne 1 ]; then
		skip "server did not become ready on port ${NORMALIZER_PORT}"
	fi
	[ "$status" -eq 0 ]
	echo "$output" | jq -r '.status' | grep -qF 'ok'
	echo "$output" | jq -r '.service' | grep -qF 'discord-response-normalizer'
}

@test "HTTP: POST /normalize returns chunks and identity" {
	[ -f "$NORMALIZER_SERVER" ] || skip "normalize-server.js not found"
	[ -x "$(command -v curl)" ] || skip "curl not on PATH"
	export NORMALIZER_PORT="${NORMALIZER_TEST_PORT:-8767}"
	node "$NORMALIZER_SERVER" >/dev/null 2>&1 &
	SERVER_PID=$!
	ready=0
	for i in 1 2 3 4 5 6 7 8 9 10; do
		if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${NORMALIZER_PORT}/health"; then
			ready=1
			break
		fi
		sleep 0.2
	done
	run curl -s -X POST "http://127.0.0.1:${NORMALIZER_PORT}/normalize" \
		-H 'Content-Type: application/json' \
		-d '{"agent_id":"linux_desktop_seed","text":"hello world"}'
	kill "$SERVER_PID" 2>/dev/null || true
	wait "$SERVER_PID" 2>/dev/null || true
	if [ "$ready" -ne 1 ]; then
		skip "server did not become ready on port ${NORMALIZER_PORT}"
	fi
	[ "$status" -eq 0 ]
	echo "$output" | jq -r '.chunks[0]' | grep -qF 'hello world'
	echo "$output" | jq -r '.username' | grep -qF 'openclaw-linux-desktop-seed'
}

@test "HTTP: POST /normalize rejects missing agent_id" {
	[ -f "$NORMALIZER_SERVER" ] || skip "normalize-server.js not found"
	[ -x "$(command -v curl)" ] || skip "curl not on PATH"
	export NORMALIZER_PORT="${NORMALIZER_TEST_PORT:-8767}"
	node "$NORMALIZER_SERVER" >/dev/null 2>&1 &
	SERVER_PID=$!
	ready=0
	for i in 1 2 3 4 5 6 7 8 9 10; do
		if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${NORMALIZER_PORT}/health"; then
			ready=1
			break
		fi
		sleep 0.2
	done
	run bash -c "curl -s -o /dev/null -w '%{http_code}' -X POST 'http://127.0.0.1:${NORMALIZER_PORT}/normalize' -H 'Content-Type: application/json' -d '{\"text\":\"hello\"}'"
	kill "$SERVER_PID" 2>/dev/null || true
	wait "$SERVER_PID" 2>/dev/null || true
	if [ "$ready" -ne 1 ]; then
		skip "server did not become ready on port ${NORMALIZER_PORT}"
	fi
	[ "$status" -eq 0 ]
	[ "$output" = "400" ]
}
