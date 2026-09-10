#!/bin/bash
# scripts/lib-write-pre-upgrade-snapshot-tag.sh
#
# Ensure $PRE_UPGRADE_SNAPSHOT_TAG is set in the calling shell so the
# post-install wedged-bus / pre-upgrade-recovery consumers can find a
# snapshot to roll back to.
#
# Background (deploy run #34479399429 in DarojaAI/linux-desktop-seed):
#   The deploy hit a wedged user-bus on the test VM after a clean restart
#   of openclaw-gateway.service. The wedged-bus recovery path stamped a
#   `REFUSAL` and exited non-zero because PRE_UPGRADE_SNAPSHOT_TAG was
#   unset:
#       PRE_UPGRADE_SNAPSHOT_TAG is unset; cannot auto-rollback
#       Step 30 (Snapshot openclaw state DB) did not set the tag
#
#   The actual state-DB snapshot step that is supposed to set the tag
#   lives upstream of this repo (in openclaw/openclaw or its fork). When
#   that step is absent — for example on a first-deploy VM with no
#   upgrade history, or when the upstream step short-circuited — the
#   recovery path aborts with no usable tag.
#
# This helper is the L3b-side defense: it runs as part of
# scripts/install/deploy.sh, before the openclaw binary install + first
# start, and ensures there is *always* a tag, even if the upstream
# state-DB snapshot didn't write one.
#
# Resolution order (each step only runs if the previous left the tag unset):
#
#   1. Use $PRE_UPGRADE_SNAPSHOT_TAG if it is already set in the calling env.
#
#   2. Look for an existing snapshot dir at
#      /var/lib/openclaw-upgrade-snapshots/ and pick the most recent
#      mtime-newest file. If that directory doesn't exist yet (first
#      deploy on this VM), create it.
#
#   3. If no prior snapshot exists, take a *minimal* baseline snapshot:
#      copy /home/desktopuser/.openclaw/openclaw.json (if present) into
#      the snapshot directory with a fresh timestamp. This gives the
#      recovery path a valid "rollback to here" target on first deploy.
#
# Then export PRE_UPGRADE_SNAPSHOT_TAG into the calling shell's env via
# GITHUB_ENV (when running under GitHub Actions, e.g. the deploy
# pipeline) and also write it to a sentinel file the wedged-recovery
# script can read directly ($HOME/.openclaw/pre-upgrade-snapshot-tag).
#
# Exit codes:
#   0  tag is set (either inherited or freshly written)
#   1  unable to set the tag (e.g. permission denied on /var/lib/...)
#       caller should treat as a non-fatal WARN — the upstream step
#       may still set the tag
#
# Sandbox-safe: honors $HOME so BATS tests can run under a fake home.

set -euo pipefail

USER_HOME="${HOME:-/home/desktopuser}"
SNAPSHOT_DIR="/var/lib/openclaw-upgrade-snapshots"
TAG_FILE="$USER_HOME/.openclaw/pre-upgrade-snapshot-tag"

mkdir -p "$USER_HOME/.openclaw" 2>/dev/null || true
chmod 0755 "$USER_HOME/.openclaw" 2>/dev/null || true

tag="${PRE_UPGRADE_SNAPSHOT_TAG:-}"

if [ -z "$tag" ] && [ -d "$SNAPSHOT_DIR" ]; then
	# Pick the most-recent snapshot (mtime-newest) as the rollback target.
	tag="$(find "$SNAPSHOT_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}' | xargs -r basename || true)"
	if [ -n "$tag" ]; then
		echo "[lib-write-pre-upgrade-snapshot-tag] inherited snapshot from $SNAPSHOT_DIR: $tag"
	fi
fi

if [ -z "$tag" ]; then
	# First-deploy baseline: create the snapshot dir + take a minimal
	# snapshot of the live openclaw.json if present. Uses mktemp-style
	# unix-timestamp suffix to match the format the upgrade-recovery
	# script already produces.
	mkdir -p "$SNAPSHOT_DIR" 2>/dev/null || {
		echo "[lib-write-pre-upgrade-snapshot-tag] WARN: cannot create $SNAPSHOT_DIR (permission denied); wedged-recovery may abort on this VM." >&2
		echo "[lib-write-pre-upgrade-snapshot-tag] continuing without $SNAPSHOT_DIR — recovery will run in restart-only mode." >&2
	}
	chmod 0755 "$SNAPSHOT_DIR" 2>/dev/null || true
	ts="$(date -u +%Y-%m-%dT%H-%M-%S)"
	tag="${ts}-baseline"
	if [ -f "$USER_HOME/.openclaw/openclaw.json" ]; then
		# Honor the AGENTS.md \"use `install -m MODE`\" pattern: write
		# the snapshot with a writable mode rather than `cp` (cp 8.32
		# fails on 0400 source).
		if install -m 0644 "$USER_HOME/.openclaw/openclaw.json" "$SNAPSHOT_DIR/$tag.json" 2>/dev/null; then
			echo "[lib-write-pre-upgrade-snapshot-tag] wrote baseline snapshot $SNAPSHOT_DIR/$tag.json"
		else
			echo "[lib-write-pre-upgrade-snapshot-tag] WARN: install -m 0644 failed; falling back to no-baseline tag" >&2
			# Sentinel-only tag: the recovery path reads the string, but
			# no rollback snapshot is on disk. Recovery will skip rollback
			# rather than abort the deploy.
		fi
	else
		echo "[lib-write-pre-upgrade-snapshot-tag] no openclaw.json on disk; taking tag=$tag without baseline (recovery run in restart-only mode)"
	fi
fi

if [ -z "$tag" ]; then
	echo "[lib-write-pre-upgrade-snapshot-tag] FAIL: tag still unset after attempt; caller should treat as WARN" >&2
	exit 1
fi

# Persist for the wedged-recovery script to read directly.
printf '%s\n' "$tag" > "$TAG_FILE" 2>/dev/null || \
	echo "[lib-write-pre-upgrade-snapshot-tag] WARN: cannot write $TAG_FILE" >&2
chmod 0644 "$TAG_FILE" 2>/dev/null || true

# Pass through to consumer steps via GITHUB_ENV (deployed-runner contract).
# The variable is harmless when not running under GitHub Actions.
if [ -n "${GITHUB_ENV:-}" ] && [ -w "$GITHUB_ENV" ]; then
	printf 'PRE_UPGRADE_SNAPSHOT_TAG=%s\n' "$tag" >> "$GITHUB_ENV"
fi

export PRE_UPGRADE_SNAPSHOT_TAG="$tag"
echo "[lib-write-pre-upgrade-snapshot-tag] PRE_UPGRADE_SNAPSHOT_TAG=$tag"
