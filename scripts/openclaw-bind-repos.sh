#!/bin/bash
set -euo pipefail

# Fetch OpenClaw bindings and apply them on the remote server
# Usage: bash openclaw-bind-repos.sh <server_ip> <target_env> <target_repos_json>
# Remote scripts live in scripts/remote/ and are SCP'd to the server per run.

SERVER_IP="$1"
TARGET_ENV="$2"
TARGET_REPOS="$3"

if [ -z "$SERVER_IP" ] || [ -z "$TARGET_ENV" ] || [ -z "$TARGET_REPOS" ]; then
	echo "Usage: $0 <server_ip> <target_env> <target_repos_json>"
	exit 1
fi

echo "Processing target repos for environment: $TARGET_ENV"
echo "Target repos: $TARGET_REPOS"

if [ "$TARGET_REPOS" = "[]" ] || [ -z "$TARGET_REPOS" ]; then
	echo "No repos to configure - skipping OpenClaw bindings"
	exit 0
fi

# ── Phase 0: Classify entries ────────────────────────────────────
# Sort repos into two buckets:
#   * workspace_repo (default) — has a GitHub repo on
#     github.com/<owner>/<repo>. Phase 3 clones, Phase 4 configures.
#   * lone_agent              — agent has no matching GitHub repo.
#     Found by `gh api repos/<owner>/<repo>` returning 404. Phase 3
#     is skipped; Phase 4 calls configure-lone-agent.sh to materialize
#     `~/.openclaw/agents/<agent_id>/agent/agent-config.yaml` directly.
#     Closes the contract-vs-config drift class: an agent like
#     `ai_governance` (in dat-contract.yaml's agent_mcp_bindings but
#     without a GitHub repo anchor) belongs on the VM but had no
#     materialization path before.
echo "=========================================="
echo "Phase 0: Classifying entries (workspace vs lone)..."
echo "=========================================="
LONE_AGENTS=()
WORKSPACE_REPOS=()
while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    if GH_TOKEN="$VM_GITHUB_TOKEN" gh api "repos/$ENTRY" --jq '.id' >/dev/null 2>&1; then
        WORKSPACE_REPOS+=("$ENTRY")
    else
        # 404 or auth failure -> lone agent
        # An entry in TARGET_REPOS is "owner/repo"; for a lone
        # agent we synthesize "<agent_id>/<agent_id>" so the existing
        # downstream phases don't need shape-aware logic. The agent ID
        # is the second segment (lower-cased to canonical form).
        AGENT_ID=$(echo "$ENTRY" | cut -d'/' -f2 | tr '[:upper:]' '[:lower:]' | tr '-' '_')
        LONE_AGENTS+=("$AGENT_ID")
    fi
done < <(echo "$TARGET_REPOS" | jq -r '.[]')

if [ "${#LONE_AGENTS[@]}" -gt 0 ]; then
    echo "Lone agents: ${LONE_AGENTS[*]}"
fi
if [ "${#WORKSPACE_REPOS[@]}" -gt 0 ]; then
    echo "Workspace repos: ${WORKSPACE_REPOS[*]}"
fi
# Replace TARGET_REPOS with the workspace-only list for the rest of
# the script. Lone agents get their own Phase 4b sub-step further down.
TARGET_REPOS=$(printf '%s\n' "${WORKSPACE_REPOS[@]}" | jq -R . | jq -s 'map(select(. != ""))')

# ── Phase 1: Pre-fetch all channel IDs in parallel ──
echo "=========================================="
echo "Phase 1: Fetching Discord channel IDs..."
echo "=========================================="

CHANNEL_VAR="OPENCLAW_${TARGET_ENV^^}_DISCORD_CHANNEL"
CHANNELS_FILE=$(mktemp)
export CHANNELS_FILE CHANNEL_VAR VM_GITHUB_TOKEN

fetch_channel() {
	local REPO_FULL="$1"
	local TARGET_OWNER TARGET_REPO CH_ID
	TARGET_OWNER=$(echo "$REPO_FULL" | cut -d'/' -f1)
	TARGET_REPO=$(echo "$REPO_FULL" | cut -d'/' -f2)

	local ERR_FILE
	ERR_FILE=$(mktemp)

	RAW=$(GH_TOKEN="$VM_GITHUB_TOKEN" gh api "repos/$TARGET_OWNER/$TARGET_REPO/actions/variables" \
		--jq ".variables[] | select(.name == \"$CHANNEL_VAR\") | .value" 2>"$ERR_FILE")
	GH_EXIT=$?

	# If gh command itself failed, print the actual error and abort
	if [ $GH_EXIT -ne 0 ]; then
		local ERR_MSG
		ERR_MSG=$(cat "$ERR_FILE" | head -n 1)
		echo "[ERROR] $REPO_FULL — gh API failed: $ERR_MSG" >&2
		rm -f "$ERR_FILE"
		return 0
	fi

	# If API returned empty, the variable genuinely doesn't exist
	if [ -z "$RAW" ]; then
		echo "[SKIP] $REPO_FULL — $CHANNEL_VAR not found in repo variables"
		rm -f "$ERR_FILE"
		return 0
	fi

	# If API returned JSON (error object), report it clearly
	if echo "$RAW" | grep -qE '^\s*\{'; then
		echo "[ERROR] $REPO_FULL — GitHub API returned error JSON: $RAW" >&2
		rm -f "$ERR_FILE"
		return 0
	fi

	# Validate channel ID is numeric 17-20 digits before accepting
	if ! echo "$RAW" | grep -qE '^[0-9]{17,20}$'; then
		echo "[SKIP] $REPO_FULL — invalid channel ID format: '$RAW'"
		rm -f "$ERR_FILE"
		return 0
	fi

	CH_ID="$RAW"
	(
		flock -x 200
		echo "$REPO_FULL $CH_ID" >> "$CHANNELS_FILE"
	) 200>"${CHANNELS_FILE}.lock"
	echo "[OK] $REPO_FULL -> $CH_ID"
	rm -f "$ERR_FILE"
}
export -f fetch_channel

echo "$TARGET_REPOS" | jq -r '.[]' | xargs -P 4 -I {} bash -c 'fetch_channel "$@"' _ {}

unset -f fetch_channel
export CHANNELS_FILE

#
# Trap handler: always re-lock the live config, even if the script
# exits early (Phase 1 failure, Phase 4 failure, SIGTERM, etc.).
# Without this, a mid-script failure leaves openclaw.json mode 0666
# and writable by any agent on the system.
trap 'ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" "chmod 444 /home/desktopuser/.openclaw/openclaw.json" 2>/dev/null || true' EXIT

# ── Phase 2: Unlock config on server ──
# Self-healing: if /home/desktopuser/.openclaw/openclaw.json is missing,
# create it as an empty file owned by desktopuser (mode 0644) before
# chmod-ing to 0666 for the bind operation. Without this, a fresh VM
# (or one whose openclaw.json was deleted out from under us) fails with
# "ERROR: Config file not writable by desktopuser" because chmod 666
# on a missing file is a no-op and test -w returns false.
# Ref: deploy-staleness incident 2026-08-12, runs 31604107068 /
# 31608758814 / 31611156763.
#
# Each command echoes its result on failure so the deploy log surfaces
# the actual root cause when 'test -w' later trips, instead of the bare
# "ERROR: Config file not writable by desktopuser" line.
echo "=========================================="
echo "Phase 2: Unlocking config on server..."
echo "=========================================="

ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
	"set -e; \
	 mkdir -p /home/desktopuser/.openclaw || { echo 'PHASE2_FAIL: mkdir failed'; exit 1; }; \
	 if [ ! -f /home/desktopuser/.openclaw/openclaw.json ]; then \
	   install -m 0644 /dev/null /home/desktopuser/.openclaw/openclaw.json || { echo 'PHASE2_FAIL: install failed'; exit 1; }; \
	   echo 'PHASE2_HEAL: created openclaw.json (was missing)'; \
	 else \
	   echo 'PHASE2_HEAL: openclaw.json exists, skipping install'; \
	 fi; \
	 stat -c 'PHASE2_BEFORE_CHMOD: %n mode=%a owner=%U:%G size=%s' /home/desktopuser/.openclaw /home/desktopuser/.openclaw/openclaw.json; \
	 chmod 755 /home/desktopuser/.openclaw || { echo 'PHASE2_FAIL: chmod 755 .openclaw failed'; exit 1; }; \
	 chmod 666 /home/desktopuser/.openclaw/openclaw.json || { echo 'PHASE2_FAIL: chmod 666 openclaw.json failed'; exit 1; }; \
	 stat -c 'PHASE2_AFTER_CHMOD: %n mode=%a owner=%U:%G size=%s' /home/desktopuser/.openclaw /home/desktopuser/.openclaw/openclaw.json"

W_CHECK_OUTPUT=$(ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
	"stat -c '%a %U:%G' /home/desktopuser/.openclaw/openclaw.json 2>&1; echo PHASE2_TEST_W_RC=\$?" 2>&1)
echo "$W_CHECK_OUTPUT" | sed 's/^/PHASE2_TEST_W: /'
if ! ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
	"[ -w /home/desktopuser/.openclaw/openclaw.json ]" 2>/dev/null; then
	echo "ERROR: Config file not writable by desktopuser"
	echo "PHASE2_DIAG: above PHASE2_* lines explain the file state"
	exit 1
fi

# ── Phase 3: Ensure repos in parallel ──
echo "=========================================="
echo "Phase 3: Cloning/updating repos on server..."
echo "=========================================="

ensure_repo() {
	local REPO_FULL="$1"
	local TARGET_OWNER TARGET_REPO
	TARGET_OWNER=$(echo "$REPO_FULL" | cut -d'/' -f1)
	TARGET_REPO=$(echo "$REPO_FULL" | cut -d'/' -f2)
	ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
		"VM_GITHUB_TOKEN=$VM_GITHUB_TOKEN bash /home/desktopuser/.openclaw/scripts/remote/ensure-repo.sh '$TARGET_OWNER' '$TARGET_REPO'" \
		2>/dev/null && echo "[OK] $REPO_FULL" || echo "[FAIL] $REPO_FULL"
}
export -f ensure_repo

echo "$TARGET_REPOS" | jq -r '.[]' | xargs -P 4 -I {} bash -c 'ensure_repo "$@"' _ {}
unset -f ensure_repo

# Phase 4 wrapped in `set +e`: a per-agent provisioning failure
# (e.g. the openrouter-provision.py predicate bug from PR #87, or any
# 5xx from OpenRouter's /api/v1/keys endpoint) must NOT abort the
# script before Phase 5 writes override.conf. Without this, the
# deploy chain's verify-override-conf gate at Layer 1 fires on
# `actual == pre` (file on disk unchanged), and Phase 5 never runs.
# The deploy chain already has its own gate handling for Phase 4
# outcomes via PR #1468's continue-on-error: true. We restore `set -e`
# before Phase 5 so downstream failure surfacing stays loud.
set +e

# ── Phase 4: Configure agents sequentially ──
echo "=========================================="
echo "Phase 4: Configuring agents..."
echo "=========================================="

ALL_CHANNEL_IDS=""
while IFS=' ' read -r REPO_FULL CH_ID; do
	[ -z "$REPO_FULL" ] && continue
	TARGET_REPO=$(echo "$REPO_FULL" | cut -d'/' -f2)
	echo "Binding: $TARGET_REPO -> $CH_ID"
	ssh -n -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
		"bash /home/desktopuser/.openclaw/scripts/remote/configure-openclaw-agent.sh '$TARGET_REPO' '$CH_ID'"

	if ! echo "$ALL_CHANNEL_IDS" | grep -q "\"$CH_ID\""; then
		if [ -z "$ALL_CHANNEL_IDS" ]; then
			ALL_CHANNEL_IDS="\"$CH_ID\""
		else
			ALL_CHANNEL_IDS="$ALL_CHANNEL_IDS \"$CH_ID\""
		fi
	fi
done < "$CHANNELS_FILE"

rm -f "$CHANNELS_FILE" "${CHANNELS_FILE}.lock"

# Phase 4 done; restore strict-fail semantics for Phase 5 onward.
set -e

# ── Phase 4b: Materialize lone agents ───────────────────────────────
# For each agent classified as lone in Phase 0 (no GitHub repo anchor),
# call configure-lone-agent.sh to write a minimal `agent-config.yaml`
# at ~/.openclaw/agents/<agent_id>/agent/. This closes the contract-vs-
# config drift class: an agent in dat-contract.yaml's agent_mcp_bindings
# that has no matching GitHub repo gets materialized without requiring
# a workspace clone.
#
# Run with `set +e` because per-agent failure should not abort the rest
# of the bind chain. Failures are reported in the deploy log and the
# verify step (post-deploy-verify-provisioning.sh) will surface the gap.
set +e
if [ "${#LONE_AGENTS[@]}" -gt 0 ]; then
    echo "=========================================="
    echo "Phase 4b: Materializing lone agents..."
    echo "=========================================="
    for AGENT_ID in "${LONE_AGENTS[@]}"; do
        echo "Lone agent: $AGENT_ID"
        if ssh -n -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
            "OPENCLAW_APP_USER=desktopuser bash /home/desktopuser/.openclaw/scripts/remote/configure-lone-agent.sh '$AGENT_ID'" \
            2>&1; then
            echo "[OK] lone agent $AGENT_ID materialized"
        else
            echo "[FAIL] lone agent $AGENT_ID materialization failed"
        fi
    done
fi
set -e

# ── Phase 5: Update Discord token ──
echo "=========================================="
echo "Phase 5: Updating Discord token..."
echo "=========================================="

if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then
	echo "ERROR: DISCORD_BOT_TOKEN not set"
	exit 1
fi

ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
	"DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN GATEWAY_AUTH_TOKEN=${GATEWAY_AUTH_TOKEN:-} OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-} OPENROUTER_PROVISIONING_KEY=${OPENROUTER_PROVISIONING_KEY:-} bash /home/desktopuser/.openclaw/scripts/remote/update-discord-token.sh"

# ── Phase 6: Update guilds channels ──
if [ -n "$ALL_CHANNEL_IDS" ]; then
	echo "=========================================="
	echo "Phase 6: Updating guilds channels..."
	echo "=========================================="

	ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
		"chmod 666 /home/desktopuser/.openclaw/openclaw.json"

	scp -o StrictHostKeyChecking=no \
		scripts/openclaw-update-guilds.py "${SSH_USER}@${SERVER_IP}:/tmp/openclaw-update-guilds.py"

	GUILD_ID="${DISCORD_GUILD_ID:-1485047825967480862}"
	CONFIG_FILE="/home/desktopuser/.openclaw/openclaw.json"

	CHANNEL_ARGS=""
	for ch in $ALL_CHANNEL_IDS; do
		ch_clean="${ch//\"/}"
		CHANNEL_ARGS="$CHANNEL_ARGS $ch_clean"
	done

	# SSH session is already desktopuser@${SERVER_IP}; sudo -u desktopuser
	# is redundant and rejected by the post-2026-06-22 hardened sudoers
	# (PR #968). Drop the wrapper.
	ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
		"python3 /tmp/openclaw-update-guilds.py \"$CONFIG_FILE\" \"$GUILD_ID\" $CHANNEL_ARGS"
fi

# ── Phase 7: Restart gateway — ONLY after active-session check ──
# CRITICAL: The main user conversation session is stored in .jsonl files on disk.
# A gateway restart clears the in-memory session binding cache, which can cause
# Discord messages to open fresh sessions instead of restoring existing ones.
# We MUST check for active .jsonl sessions before restarting.
echo "=========================================="
echo "Phase 7: Restarting gateway..."
echo "=========================================="

SKIP_RESTART=0

SCRIPT_ON_VM=$(
	ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
		"test -f /home/desktopuser/.openclaw/scripts/monitor/check-active-sessions.sh && echo found" \
		2>/dev/null || echo ""
)

if [[ "$SCRIPT_ON_VM" == "found" ]]; then
	echo "Checking for active sessions..."
	if ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
		"bash /home/desktopuser/.openclaw/scripts/monitor/check-active-sessions.sh '$SERVER_IP'" 2>&1; then
		echo "No active sessions — gateway may be restarted."
	else
		echo "ACTIVE SESSIONS DETECTED — skipping gateway restart to preserve conversation memory."
		echo "Config changes will take effect on next gateway start."
		SKIP_RESTART=1
	fi
else
	# Inline fallback — used before the script is deployed to the VM
	MAIN_ACTIVE=$(ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
		'python3 -c "
import json, os, glob
from datetime import datetime, timezone

threshold = 15 * 60  # 15 minutes
for sd in glob.glob('\''/home/desktopuser/.openclaw/agents/*/sessions'\''):
    for sf in glob.glob(os.path.join(sd, '\''*.jsonl'\'')):
        try:
            with open(sf) as f:
                lines = f.readlines()
            if not lines:
                continue
            last = json.loads(lines[-1].strip())
            ts = last.get('\''timestamp'\'') or last.get('\''created_at'\'')
            if not ts:
                continue
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(ts.replace('\''Z'\'','\''+00:00'\''))).total_seconds()
            if age <= threshold:
                print('\''active: '\'' + os.path.basename(sf))
        except Exception:
            pass
print('\''done'\'')
" 2>/dev/null' || true)

	if echo "$MAIN_ACTIVE" | grep -q "active:"; then
		echo "ACTIVE SESSIONS DETECTED — skipping gateway restart to preserve conversation memory."
		SKIP_RESTART=1
	else
		echo "No active main sessions found — gateway may be restarted."
	fi
fi

if [[ "$SKIP_RESTART" -eq 1 ]]; then
	echo "Skipping restart. Config changes will take effect on next gateway start."
else
	ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" bash <<'RESTART_SCRIPT'
	set -e
	# SSH session is already desktopuser@${SERVER_IP}; sudo -u desktopuser
	# is rejected by the post-2026-06-22 hardened sudoers (PR #968) for
	# arbitrary commands. XDG_RUNTIME_DIR=... as a per-command env-var
	# prefix is honored by bash directly without invoking sudo.
	XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload
	if XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active --quiet openclaw-gateway.service 2>/dev/null; then
		XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart openclaw-gateway.service
		echo "Gateway restarted"
	else
		echo "Gateway not active; skipping restart"
	fi
RESTART_SCRIPT
fi

# Cleanup
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
	"rm -f /tmp/openclaw-update-guilds.py"

# Re-lock config
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
	"chmod 444 /home/desktopuser/.openclaw/openclaw.json" 2>/dev/null || true

echo "All OpenClaw bindings processed"