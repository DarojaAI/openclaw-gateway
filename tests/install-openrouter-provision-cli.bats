#!/usr/bin/env bats
#
# tests/install-openrouter-provision-cli.bats
#
# Tests for step 4b of scripts/install/deploy.sh: install the
# openrouter-provision CLI to /usr/local/bin/openrouter-provision.
#
# Why this phase exists
# ---------------------
# The seed's configure-openclaw-agent.sh invokes
# /usr/local/bin/openrouter-provision (the binary this repo ships at
# scripts/openrouter-provision.py) to mint per-agent child keys.
# Before step 4b existed, no install path placed the binary on the
# VM. The gateway clone put it at /tmp/openclaw-gateway/... but
# nothing copied it to /usr/local/bin/, so configure-openclaw-agent.sh
# silently fell back to the shared OPENROUTER_API_KEY on every
# deploy (incident: linux-desktop-seed run 27833801264, 2026-06-19).
#
# The phase must:
#   1. Copy scripts/openrouter-provision.py to /usr/local/bin/openrouter-provision
#      with mode 0755.
#   2. Be idempotent on a second run (same source SHA → skip, no extra copy).
#   3. Re-install when the source SHA changes.
#   4. Warn (not fail) when the source file is missing.
#   5. Use install(1) with mode 0755 (per AGENTS.md deploy-snapshot
#      incident: cp 8.32 fails against 0400 source/dest under some kernels).
#   6. Honor $HOME and a configurable install dir so it works in a
#      sandboxed test env (real /usr/local/bin is not writable from
#      a CI sandbox).

setup() {
	# Sandbox the install dir so we don't touch the real /usr/local/bin
	export TEST_PREFIX="$(mktemp -d)"
	export OPENROUTER_PROVISION_INSTALL_DIR="$TEST_PREFIX/usr/local/bin"
	mkdir -p "$OPENROUTER_PROVISION_INSTALL_DIR"

	REPO_ROOT="$(pwd)"
	export REPO_ROOT
}

teardown() {
	# Defensive restore in case a test moved the source file and
	# failed before restoring it (bats doesn't always run trap
	# handlers on assertion failures inside `run`).
	if [ -f "$REPO_ROOT/scripts/openrouter-provision.py.bak" ]; then
		mv "$REPO_ROOT/scripts/openrouter-provision.py.bak" "$REPO_ROOT/scripts/openrouter-provision.py"
	fi
	rm -rf "$TEST_PREFIX"
	unset OPENROUTER_PROVISION_INSTALL_DIR
}

# Run only step 4b of deploy.sh in a subshell. We source the same
# log helpers and replicate the install block; keep these two in
# sync (the bats tests are the contract). stdout and stderr are
# merged so WARN lines (which go to stderr in production) are
# captured in $output by bats `run`.
run_provision_install() {
	(
		set -euo pipefail
		REPO_ROOT="$REPO_ROOT"
		OPENROUTER_PROVISION_INSTALL_DIR="$OPENROUTER_PROVISION_INSTALL_DIR"

		log_info() { echo "[INFO] $*"; }
		log_warn() { echo "[WARN] $*" >&2; }
		log_error() { echo "[ERROR] $*" >&2; }

		provision_src="$REPO_ROOT/scripts/openrouter-provision.py"
		provision_dst="$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision"
		if [[ -f "$provision_src" ]]; then
			if [[ -f "$provision_dst" ]] && cmp -s "$provision_src" "$provision_dst"; then
				log_info "openrouter-provision already installed and up-to-date"
			else
				log_info "Installing openrouter-provision CLI..."
				install -m 0755 "$provision_src" "$provision_dst"
				log_info "openrouter-provision CLI installed to $provision_dst"
			fi
		else
			log_warn "openrouter-provision source not found at $provision_src"
		fi
	) 2>&1
}

@test "installs the binary to OPENROUTER_PROVISION_INSTALL_DIR" {
	run run_provision_install
	[ "$status" -eq 0 ]
	[[ "$output" == *"Installing openrouter-provision CLI..."* ]]
	[[ "$output" == *"installed to $OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision"* ]]
	[ -f "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision" ]
}

@test "installed file has mode 0755" {
	run run_provision_install
	[ "$status" -eq 0 ]
	[ -f "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision" ]
	local_mode="$(stat -c '%a' "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision")"
	[ "$local_mode" = "755" ]
}

@test "installed file is byte-identical to source" {
	run run_provision_install
	[ "$status" -eq 0 ]
	cmp "$REPO_ROOT/scripts/openrouter-provision.py" "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision"
}

@test "is idempotent on second run (no extra copy)" {
	run run_provision_install
	[ "$status" -eq 0 ]
	[[ "$output" == *"Installing openrouter-provision CLI..."* ]]

	# Second run: should NOT re-install; same SHA, skip.
	run run_provision_install
	[ "$status" -eq 0 ]
	[[ "$output" == *"already installed and up-to-date"* ]]
	[[ "$output" != *"Installing openrouter-provision CLI..."* ]]
}

@test "re-installs when source SHA changes" {
	# First install
	run run_provision_install
	[ "$status" -eq 0 ]

	# Mutate the destination to simulate drift
	echo "# stale content" >> "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision"

	# Second run: should detect drift and re-install
	run run_provision_install
	[ "$status" -eq 0 ]
	[[ "$output" == *"Installing openrouter-provision CLI..."* ]]

	# Verify the destination matches the source again
	cmp "$REPO_ROOT/scripts/openrouter-provision.py" "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision"
}

@test "warns (not fails) when source is missing" {
	# Temporarily hide the source file. Restore BEFORE asserting so
	# subsequent tests have the file (bats `run` does not run trap
	# handlers on assertion failures). teardown() also restores as
	# a belt-and-suspenders safety net.
	mv "$REPO_ROOT/scripts/openrouter-provision.py" "$REPO_ROOT/scripts/openrouter-provision.py.bak"

	run run_provision_install
	local_status="$status"
	local_output="$output"

	# Restore immediately, regardless of pass/fail.
	mv "$REPO_ROOT/scripts/openrouter-provision.py.bak" "$REPO_ROOT/scripts/openrouter-provision.py"

	[ "$local_status" -eq 0 ]
	[[ "$local_output" == *"[WARN] openrouter-provision source not found"* ]]
	[ ! -f "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision" ]
}

@test "does not fail when destination directory already exists" {
	# Pre-create the destination file with wrong content to force overwrite
	mkdir -p "$OPENROUTER_PROVISION_INSTALL_DIR"
	echo "leftover" > "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision"
	chmod 0644 "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision"

	run run_provision_install
	[ "$status" -eq 0 ]

	# File should now match source and have mode 0755
	cmp "$REPO_ROOT/scripts/openrouter-provision.py" "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision"
	local_mode="$(stat -c '%a' "$OPENROUTER_PROVISION_INSTALL_DIR/openrouter-provision")"
	[ "$local_mode" = "755" ]
}
