#!/usr/bin/env bats
#
# tests/post-deploy-verify-memory-index.bats
#
# Tests for the post-deploy memory-index health gate.
#
# Why this phase exists
# ---------------------
# DarojaAI/openclaw-gateway#21: `memory_search` returns
# `disabled: true, unavailable: true, error: "index metadata is missing"`
# when the on-disk memory index sidecar is missing or was written by a
# different embedding provider/model. The deploy gate needs to catch
# this *before* declaring a deploy healthy, otherwise the agent learns
# about the broken state only when an end-user calls memory_search.
#
# Upstream openclaw/openclaw owns the underlying race fix (PR #90453);
# this script is the L3b-side detection and the deploy-gate
# integration. The unit-of-one tests here are for the decision logic
# (parser) and the bash wiring.
#
# The phase must:
#   1. Exit 0 when all agents have a healthy indexIdentity.
#   2. Exit 0 with a WARN line on a fresh install (chunks=0, dirty).
#   3. Exit 1 when at least one agent has a missing/mismatched
#      indexIdentity AND has data that should be indexed.
#   4. Exit 1 even on a fresh install when
#      MEMORY_CHECK_FAIL_ON_FRESH=1 is set.
#   5. Exit 2 (probe failure) when openclaw is not on PATH.
#   6. Exit 2 (probe failure) when openclaw memory status --json emits
#      invalid JSON.
#   7. Exit 0 (no-op) when SKIP_POST_DEPLOY_MEMORY_CHECK=1.
#   8. WARN (not FAIL) on provider/requestedProvider divergence.
#   9. Use a separate parser file (lib-parse-memory-status.py) — the
#      bash side must not embed a python heredoc that swallows the
#      JSON pipe.
#  10. The script is referenced by scripts/install/deploy.sh as
#      section 9 (post-deploy memory-index verification).
#
# Stub strategy: a fake `openclaw` script in a temp dir, on PATH, that
# prints canned JSON for `openclaw memory status --json` and exits
# non-zero for everything else. The stub uses a marker file
# $FAKE_OPENCLAW_OUT to select which JSON to emit, so a single stub
# can simulate several states from the test body.

setup() {
	export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	export SCRIPT="$REPO_ROOT/scripts/post-deploy-verify-memory-index.sh"
	export PARSER="$REPO_ROOT/scripts/lib-parse-memory-status.py"

	# Sandbox: drop a fake `openclaw` ahead of the real one.
	export TEST_BIN="$(mktemp -d)"
	export FAKE_OPENCLAW_OUT="$TEST_BIN/canned.json"
	export PATH="$TEST_BIN:$PATH"

	cat >"$TEST_BIN/openclaw" <<'STUB'
#!/usr/bin/env bash
# fake openclaw for post-deploy-verify-memory-index tests
if [[ "${1:-}" == "memory" ]] && [[ "${2:-}" == "status" ]] && \
   printf '%s\n' "${@}" | grep -q -- "--json"; then
	if [[ -f "${FAKE_OPENCLAW_OUT:-}" ]]; then
		cat "$FAKE_OPENCLAW_OUT"
	else
		echo "[]"
	fi
	exit 0
fi
echo "fake openclaw: unsupported invocation: $*" >&2
exit 64
STUB
	chmod +x "$TEST_BIN/openclaw"
}

teardown() {
	rm -rf "$TEST_BIN"
	unset FAKE_OPENCLAW_OUT SKIP_POST_DEPLOY_MEMORY_CHECK MEMORY_CHECK_FAIL_ON_FRESH
}

# Convenience: write a canned agent list to FAKE_OPENCLAW_OUT.
emit() {
	printf '%s' "$1" >"$FAKE_OPENCLAW_OUT"
}

# ---- 1. Healthy: ok identity, chunks present ----
@test "passes when all agents have ok indexIdentity" {
	emit '[{"agentId":"main","status":{"chunks":12,"files":3,"provider":"openai","requestedProvider":"openai","custom":{"indexIdentity":{"status":"ok","reason":""}}},"scan":{"totalFiles":3,"issues":[]}}]'
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"OK: main"* ]]
	[[ "$output" == *"1 healthy, 0 warn, 0 fail"* ]]
}

# ---- 2. Fresh install: missing identity + zero chunks → WARN, exit 0 ----
@test "warns (does not fail) on fresh install with no chunks" {
	emit '[{"agentId":"main","status":{"chunks":0,"files":0,"provider":"openai","requestedProvider":"openai","custom":{"indexIdentity":{"status":"missing","reason":"index metadata is missing"}}},"scan":{"totalFiles":0,"issues":["memory directory missing"]}}]'
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"WARN: main [warn-fresh"* ]]
	[[ "$output" == *"0 healthy, 1 warn, 0 fail"* ]]
}

# ---- 3. Regression: missing identity + chunks present → FAIL, exit 1 ----
@test "fails when indexIdentity is missing on an agent that has indexed chunks" {
	emit '[{"agentId":"main","status":{"chunks":42,"files":7,"provider":"openai","requestedProvider":"openai","custom":{"indexIdentity":{"status":"missing","reason":"index metadata is missing"}}},"scan":{"totalFiles":7,"issues":[]}}]'
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL: 1 agent(s) have a degraded memory index"* ]]
	[[ "$output" == *"main [fail, identity=missing"* ]]
	[[ "$output" == *"openclaw memory index --force"* ]]
}

# ---- 4. Regression: identity mismatch on populated index → FAIL ----
# Note: provider and requestedProvider must match here. If they differ,
# the parser routes to the warn-swap verdict (test 7). To test the
# `mismatch` identity path specifically, we keep them equal and rely
# on the explicit `mismatch` status.
@test "fails when indexIdentity is mismatch on a populated index" {
	emit '[{"agentId":"linux_desktop_seed","status":{"chunks":100,"files":15,"provider":"openai","requestedProvider":"openai","custom":{"indexIdentity":{"status":"mismatch","reason":"provider changed"}}},"scan":{"totalFiles":15,"issues":[]}}]'
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL: 1 agent(s) have a degraded memory index"* ]]
	[[ "$output" == *"linux_desktop_seed [fail, identity=mismatch"* ]]
}

# ---- 5. Mixed: one healthy agent + one failing agent → FAIL ----
@test "fails when any single agent is degraded (multi-agent)" {
	emit '[
		{"agentId":"main","status":{"chunks":5,"files":2,"provider":"openai","requestedProvider":"openai","custom":{"indexIdentity":{"status":"ok","reason":""}}},"scan":{"totalFiles":2,"issues":[]}},
		{"agentId":"linux_desktop_seed","status":{"chunks":10,"files":3,"provider":"openai","requestedProvider":"openai","custom":{"indexIdentity":{"status":"missing","reason":"index metadata is missing"}}},"scan":{"totalFiles":3,"issues":[]}}
	]'
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"OK: main"* ]]
	[[ "$output" == *"FAIL: 1 agent(s)"* ]]
	[[ "$output" == *"linux_desktop_seed"* ]]
}

# ---- 6. MEMORY_CHECK_FAIL_ON_FRESH=1 promotes fresh-install to FAIL ----
@test "fails on fresh install when MEMORY_CHECK_FAIL_ON_FRESH=1" {
	emit '[{"agentId":"main","status":{"chunks":0,"files":0,"provider":"openai","requestedProvider":"openai","custom":{"indexIdentity":{"status":"missing","reason":"index metadata is missing"}}},"scan":{"totalFiles":0,"issues":[]}}]'
	export MEMORY_CHECK_FAIL_ON_FRESH=1
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"warn-fresh"* ]]
}

# ---- 7. Provider swap: provider != requestedProvider → WARN, exit 0 ----
@test "warns on provider/requestedProvider divergence (model swap signal)" {
	emit '[{"agentId":"main","status":{"chunks":50,"files":8,"provider":"openai","requestedProvider":"openrouter","custom":{"indexIdentity":{"status":"ok","reason":""}}},"scan":{"totalFiles":8,"issues":[]}}]'
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"warn-swap"* ]]
	[[ "$output" == *"0 healthy, 1 warn, 0 fail"* ]]
}

# ---- 8. Unknown identity state → WARN, exit 0 (forward-compat) ----
@test "warns on unrecognized identity status (forward-compatible)" {
	emit '[{"agentId":"main","status":{"chunks":1,"files":1,"provider":"openai","requestedProvider":"openai","custom":{"indexIdentity":{"status":"weird","reason":"unknown future state"}}},"scan":{"totalFiles":1,"issues":[]}}]'
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"warn-unknown"* ]]
}

# ---- 9. SKIP_POST_DEPLOY_MEMORY_CHECK=1 short-circuits ----
@test "skips entirely when SKIP_POST_DEPLOY_MEMORY_CHECK=1" {
	export SKIP_POST_DEPLOY_MEMORY_CHECK=1
	# No canned output at all — script should not even invoke openclaw.
	rm -f "$FAKE_OPENCLAW_OUT"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped"* ]]
}

# ---- 10. Probe failure: openclaw not on PATH → exit 2 ----
# Strategy: build a clean bin dir with symlinks to the system tools
# the script needs (rm, cat, python3, mktemp, sed) but with NO
# openclaw. Then point PATH at this dir only. The script's
# `command -v openclaw` lookup will fail; the script should exit 2
# cleanly without crashing on the missing-system-tools side effect.
@test "exits 2 when openclaw is not on PATH" {
	EMPTY_BIN="$(mktemp -d)"
	for tool in /usr/bin/python3 /bin/rm /bin/cat /usr/bin/sed /bin/mktemp /usr/bin/date /usr/bin/dirname /usr/bin/head /usr/bin/env /usr/bin/bash; do
		if [[ -x "$tool" ]]; then
			ln -s "$tool" "$EMPTY_BIN/$(basename "$tool")"
		fi
	done
	# Fallback for python3 if not at the standard path.
	if [[ ! -e "$EMPTY_BIN/python3" ]] && command -v python3 >/dev/null 2>&1; then
		ln -s "$(command -v python3)" "$EMPTY_BIN/python3"
	fi
	ORIG_PATH="$PATH"
	export PATH="$EMPTY_BIN"
	# Use the shebang (env needs to be on PATH; we symlinked it above).
	run "$SCRIPT"
	rc=$status
	export PATH="$ORIG_PATH"
	rm -rf "$EMPTY_BIN"
	[ "$rc" -eq 2 ]
	[[ "$output" == *"openclaw binary not found"* ]]
}

# ---- 11. Probe failure: invalid JSON → exit 2 ----
@test "exits 2 when openclaw emits invalid JSON" {
	emit 'this is not json'
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ "$output" == *"JSON parse error"* ]]
}

# ---- 12. Probe failure: empty JSON output → exit 2 ----
@test "exits 2 when openclaw emits no output" {
	# Stub exits with empty stdout if the marker file is empty.
	: >"$FAKE_OPENCLAW_OUT"
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ "$output" == *"returned no output"* ]]
}

# ---- 13. No agents in array → exit 0 (nothing to verify) ----
@test "exits 0 with a warning when no agents are reported" {
	emit '[]'
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no agents reported"* ]]
}

# ---- 14. Parser exists and is executable as Python ----
@test "the parser lib exists and is parseable" {
	[ -f "$PARSER" ]
	python3 -c "import ast; ast.parse(open('$PARSER').read())"
}

# ---- 15. Script uses the parser (no inline python heredoc) ----
@test "script does not embed a python heredoc that would swallow the JSON pipe" {
	# If a python heredoc were present, shellcheck SC2259 would fire
	# (or the script would not work). Assert the pattern is absent.
	! grep -q "python3 - <<" "$SCRIPT"
	grep -q 'lib-parse-memory-status.py' "$SCRIPT"
}

# ---- 16. Parser unit: identity=ok with chunks=0 still classifies as ok ----
@test "parser: identity=ok with chunks=0 still ok (avoids false fresh-install)" {
	emit '[{"agentId":"main","status":{"chunks":0,"files":0,"provider":"openai","requestedProvider":"openai","custom":{"indexIdentity":{"status":"ok","reason":""}}},"scan":{"totalFiles":0,"issues":[]}}]'
	run python3 "$PARSER" <"$FAKE_OPENCLAW_OUT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"main"$'\t'"ok"* ]]
}

# ---- 17. Parser unit: invalid JSON exits 3 ----
@test "parser: invalid JSON exits 3 (caller maps to exit 2)" {
	run bash -c "echo 'not json' | python3 '$PARSER'"
	[ "$status" -eq 3 ]
}

# ---- 18. Parser unit: empty array exits 4 (caller maps to exit 0 + warn) ----
@test "parser: empty array exits 4 (caller maps to exit 0 + warn)" {
	run bash -c "echo '[]' | python3 '$PARSER'"
	[ "$status" -eq 4 ]
}

# ---- 19. deploy.sh wires the new script in ----
@test "deploy.sh invokes post-deploy-verify-memory-index.sh" {
	grep -q "post-deploy-verify-memory-index.sh" "$REPO_ROOT/scripts/install/deploy.sh"
}
