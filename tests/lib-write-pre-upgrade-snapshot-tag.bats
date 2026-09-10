#!/usr/bin/env bats
#
# BATS tests for scripts/lib-write-pre-upgrade-snapshot-tag.sh.
#
# Regression pin for deploy run #34479399429 in DarojaAI/linux-desktop-seed:
# the deploy hit a wedged user-bus on a first-deploy test VM and the
# wedged-bus recovery script aborted with:
#
#   PRE_UPGRADE_SNAPSHOT_TAG is unset; cannot auto-rollback
#   Step 30 (Snapshot openclaw state DB) did not set the tag
#
# The fix is L3b-side (this repo): install/deploy.sh sources the helper
# before the gateway install + first start, ensuring $PRE_UPGRADE_SNAPSHOT_TAG
# is populated whether or not the upstream state-DB snapshot step wrote a
# tag. These tests exercise the helper in isolation.

setup() {
	# Sandbox every test under a fake $HOME so we never touch
	# /home/desktopuser/.openclaw/ or /var/lib/openclaw-upgrade-snapshots/
	# on the host.
	TEST_HOME="$(mktemp -d -t pre-up-snap.XXXXXX)"
	export HOME="$TEST_HOME"
	export GITHUB_ENV="$TEST_HOME/.github_env"
	# Clear $PRE_UPGRADE_SNAPSHOT_TAG so the helper's "inherited" branch
	# exercises its fallback path. Individual tests can override.
	unset PRE_UPGRADE_SNAPSHOT_TAG
	# Helper lives at the repo root under scripts/.
	REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	HELPER="$REPO_ROOT/scripts/lib-write-pre-upgrade-snapshot-tag.sh"
}

teardown() {
	rm -rf "$TEST_HOME" 2>/dev/null || true
	unset PRE_UPGRADE_SNAPSHOT_TAG GITHUB_ENV
}

# ── happy path: first-deploy VM with no upgrade history ────────────

@test "first-deploy (no snapshot dir, no live config): writes baseline tag" {
	# /var/lib/openclaw-upgrade-snapshots/ may not exist on a fresh VM.
	# Helper must create it OR write a sentinel tag via $HOME/.openclaw/
	# ... whichever is permitted by the CI sandbox.
	run bash "$HELPER"
	[ "$status" -eq 0 ]
	# Tag is exported to caller env.
	[ -n "$PRE_UPGRADE_SNAPSHOT_TAG" ]
	[[ "$output" == *"PRE_UPGRADE_SNAPSHOT_TAG="* ]]
	# Sentinel file under $HOME was written.
	[ -f "$HOME/.openclaw/pre-upgrade-snapshot-tag" ]
	grep -q '.' "$HOME/.openclaw/pre-upgrade-snapshot-tag"
}

@test "first-deploy baseline tag has YYYY-MM-DDTHH-MM-SS format with -baseline suffix" {
	run bash "$HELPER"
	[ "$status" -eq 0 ]
	[[ "$PRE_UPGRADE_SNAPSHOT_TAG" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z?-baseline$ ]]
}

# ── inherited tag from caller env wins ────────────────────────────

@test "inherits PRE_UPGRADE_SNAPSHOT_TAG from caller env (highest priority)" {
	export PRE_UPGRADE_SNAPSHOT_TAG="2026-09-09T15-00-00Z-inherited-explicit"
	run bash "$HELPER"
	[ "$status" -eq 0 ]
	# Sentinel file should match the inherited value verbatim.
	[ "$(cat "$HOME/.openclaw/pre-upgrade-snapshot-tag")" = "2026-09-09T15-00-00Z-inherited-explicit" ]
}

# ── existing snapshot dir + mtime-newest pick ─────────────────────

@test "picks mtime-newest existing snapshot when no inherited tag" {
	SNAP="/tmp/pre-up-snap-test-$$"
	mkdir -p "$SNAP"
	# Two prior snapshots, one older than the other.
	echo "old"  > "$SNAP/2026-01-01T00-00-00Z.json"
	echo "new"  > "$SNAP/2026-09-09T15-00-00Z.json"
	# Same helper but forced to use a custom SNAPSHOT_DIR via a wrapper.
	# The helper hardcodes /var/lib/openclaw-upgrade-snapshots; for
	# CI-sandbox determinism we override via a small wrapper that
	# symlinks /var/lib/openclaw-upgrade-snapshots -> $SNAP. Skipping
	# the symlink trick here means this test verifies the "no env, no
	# /var/lib dir exists" => baseline path, which is already covered
	# by the first test. Marking this test as a coverage-gap note.
	rm -rf "$SNAP"
	skip "SNAPSHOT_DIR is hardcoded to /var/lib/openclaw-upgrade-snapshots; cannot exercise mtime-newest pick without sudo in CI"
}

# ── GITHUB_ENV integration ─────────────────────────────────────────

@test "writes PRE_UPGRADE_SNAPSHOT_TAG to GITHUB_ENV when that file is in env" {
	: > "$GITHUB_ENV"  # ensure writable
	run bash "$HELPER"
	[ "$status" -eq 0 ]
	grep -q '^PRE_UPGRADE_SNAPSHOT_TAG=' "$GITHUB_ENV"
	# The GITHUB_ENV line and the in-shell exported value must match.
	local github_value
	github_value="$(grep '^PRE_UPGRADE_SNAPSHOT_TAG=' "$GITHUB_ENV" | cut -d= -f2)"
	[ "$github_value" = "$PRE_UPGRADE_SNAPSHOT_TAG" ]
}

@test "skips GITHUB_ENV write when GITHUB_ENV is unset (degrades gracefully)" {
	unset GITHUB_ENV
	run bash "$HELPER"
	[ "$status" -eq 0 ]
	# Still exported to caller shell + sentinel file written.
	[ -n "$PRE_UPGRADE_SNAPSHOT_TAG" ]
	[ -f "$HOME/.openclaw/pre-upgrade-snapshot-tag" ]
}

# ── sentinel file is on disk + readable ────────────────────────────

@test "sentinel file $HOME/.openclaw/pre-upgrade-snapshot-tag is mode 0644" {
	run bash "$HELPER"
	[ "$status" -eq 0 ]
	local mode
	mode="$(stat -c '%a' "$HOME/.openclaw/pre-upgrade-snapshot-tag")"
	[ "$mode" = "644" ]
}

@test "sentinel file's content matches PRE_UPGRADE_SNAPSHOT_TAG (no trailing newline corruption)" {
	run bash "$HELPER"
	[ "$status" -eq 0 ]
	# Read back the exact bytes to assert no extra \r or stripping.
	local content
	content="$(cat "$HOME/.openclaw/pre-upgrade-snapshot-tag")"
	[ "$content" = "$PRE_UPGRADE_SNAPSHOT_TAG" ]
}

# ── contract with deploy.sh ───────────────────────────────────────

@test "sourceable (deploy.sh uses `source` to inherit env, not exec)" {
	# `source` runs the script in the caller's shell; `run` would fail it
	# because `run` spawns a sub-shell that wouldn't carry $PRE_UPGRADE_SNAPSHOT_TAG.
	# Test the contract by verifying the script has the right shebang
	# and would survive `source` without re-execing the binary entry
	# point. We do this by sourcing into a sub-shell that asserts
	# $? == 0 + the env var exists.
	(
		set -e
		source "$HELPER"
		test -n "$PRE_UPGRADE_SNAPSHOT_TAG"
	)
}
