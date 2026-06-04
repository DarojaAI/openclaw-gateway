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

	CH_ID=$(GH_TOKEN="$VM_GITHUB_TOKEN" gh api "repos/$TARGET_OWNER/$TARGET_REPO/actions/variables" \
		--jq ".variables[] | select(.name == \"$CHANNEL_VAR\") | .value" 2>/dev/null) || true

	# Detect API error responses (404, 403, etc.) vs actual variable values
	if [ -n "$CH_ID" ] && echo "$CH_ID" | grep -qE '^[0-9]{17,20}$'; then
		(
			flock -x 200
			echo "$REPO_FULL $CH_ID" >> "$CHANNELS_FILE"
		) 200>"${CHANNELS_FILE}.lock"
		echo "[OK] $REPO_FULL -> $CH_ID"
	else
		if [ -n "$CH_ID" ]; then
			echo "[SKIP] $REPO_FULL (API error or invalid response: ${CH_ID:0:80})"
		else
			echo "[SKIP] $REPO_FULL (no $CHANNEL_VAR)"
		fi
	fi
}
export -f fetch_channel

echo "$TARGET_REPOS" | jq -r '.[]' | xargs -P 4 -I {} bash -c 'fetch_channel "$@"' _ {}

unset -f fetch_channel
export CHANNELS_FILE

# ── Phase 2: Unlock config on server ──
echo "=========================================="
echo "Phase 2: Unlocking config on server..."
echo "=========================================="

ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
	"chmod 755 /home/desktopuser/.openclaw && chmod 666 /home/desktopuser/.openclaw/openclaw.json"

if ! ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
	"sudo -u desktopuser test -w /home/desktopuser/.openclaw/openclaw.json" 2>/dev/null; then
	echo "ERROR: Config file not writable by desktopuser"
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
	ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
		"VM_GITHUB_TOKEN=$VM_GITHUB_TOKEN bash /home/desktopuser/.openclaw/scripts/remote/ensure-repo.sh '$TARGET_OWNER' '$TARGET_REPO'" \
		&& echo "[OK] $REPO_FULL" || echo "[FAIL] $REPO_FULL"
}
export -f ensure_repo

echo "$TARGET_REPOS" | jq -r '.[]' | xargs -P 4 -I {} bash -c 'ensure_repo "$@"' _ {}
unset -f ensure_repo

# ── Phase 4: Configure agents sequentially ──
echo "=========================================="
echo "Phase 4: Configuring agents..."
echo "=========================================="

ALL_CHANNEL_IDS=""
while IFS=' ' read -r REPO_FULL CH_ID; do
	[ -z "$REPO_FULL" ] && continue
	TARGET_REPO=$(echo "$REPO_FULL" | cut -d'/' -f2)
	echo "Binding: $TARGET_REPO -> $CH_ID"
	ssh -n -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
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

# ── Phase 5: Update Discord token ──
echo "=========================================="
echo "Phase 5: Updating Discord token..."
echo "=========================================="

if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then
	echo "ERROR: DISCORD_BOT_TOKEN not set"
	exit 1
fi

ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
	"DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN bash /home/desktopuser/.openclaw/scripts/remote/update-discord-token.sh"

# ── Phase 6: Update guilds channels ──
if [ -n "$ALL_CHANNEL_IDS" ]; then
	echo "=========================================="
	echo "Phase 6: Updating guilds channels..."
	echo "=========================================="

	ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
		"chmod 666 /home/desktopuser/.openclaw/openclaw.json"

	scp -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 \
		scripts/openclaw-update-guilds.py "root@$SERVER_IP:/tmp/openclaw-update-guilds.py"

	GUILD_ID="${DISCORD_GUILD_ID:-1485047825967480862}"
	CONFIG_FILE="/home/desktopuser/.openclaw/openclaw.json"

	CHANNEL_ARGS=""
	for ch in $ALL_CHANNEL_IDS; do
		ch_clean="${ch//\"/}"
		CHANNEL_ARGS="$CHANNEL_ARGS $ch_clean"
	done

	ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
		"sudo -u desktopuser python3 /tmp/openclaw-update-guilds.py \"$CONFIG_FILE\" \"$GUILD_ID\" $CHANNEL_ARGS"
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
	ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
		"test -f /home/desktopuser/.openclaw/scripts/monitor/check-active-sessions.sh && echo found" \
		2>/dev/null || echo ""
)

if [[ "$SCRIPT_ON_VM" == "found" ]]; then
	echo "Checking for active sessions..."
	if ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
		"bash /home/desktopuser/.openclaw/scripts/monitor/check-active-sessions.sh '$SERVER_IP'" 2>&1; then
		echo "No active sessions — gateway may be restarted."
	else
		echo "ACTIVE SESSIONS DETECTED — skipping gateway restart to preserve conversation memory."
		echo "Config changes will take effect on next gateway start."
		SKIP_RESTART=1
	fi
else
	# Inline fallback — used before the script is deployed to the VM
	MAIN_ACTIVE=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
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
	# On fresh VMs the user D-Bus bus may not exist yet — check before restarting
	ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" bash <<'RESTART_SCRIPT'
	USER_ID=$(id -u desktopuser)
	XDG_RUNTIME_DIR="/run/user/${USER_ID}"
	DBUS_ADDR="unix:path=${XDG_RUNTIME_DIR}/bus"

	if [ -S "${XDG_RUNTIME_DIR}/bus" ]; then
		if sudo -u desktopuser XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" systemctl --user is-active --quiet openclaw-gateway.service 2>/dev/null; then
			sudo -u desktopuser XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" systemctl --user restart openclaw-gateway.service
			echo "Gateway restarted"
		else
			echo "Gateway not active; skipping restart"
		fi
	else
		echo "WARN: systemd user bus not available — skipping restart, ensure step will start gateway"
	fi
RESTART_SCRIPT
fi

# Cleanup
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
	"rm -f /tmp/openclaw-update-guilds.py"

# Re-lock config
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 "root@$SERVER_IP" \
	"chmod 444 /home/desktopuser/.openclaw/openclaw.json" 2>/dev/null || true

echo "All OpenClaw bindings processed"