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

# Accumulate channel IDs for guild config update at the end
ALL_CHANNEL_IDS=""

# Unlock config file for the entire deploy process (relock at the end)
# chmod both the file AND its directory so desktopuser can write even if the directory is locked
# Use 666 so desktopuser (the owner) can write even when running via sudo -u desktopuser
echo "Unlocking openclaw.json for desktopuser write access..."
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@$SERVER_IP \
    "chmod 755 /home/desktopuser/.openclaw && chmod 666 /home/desktopuser/.openclaw/openclaw.json && ls -la /home/desktopuser/.openclaw/openclaw.json"

# Verify the file is actually writable by desktopuser (not root — root always succeeds)
echo "Verifying desktopuser write access..."
if ! ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@$SERVER_IP \
    "sudo -u desktopuser test -w /home/desktopuser/.openclaw/openclaw.json" 2>/dev/null; then
    echo "ERROR: Config file is not writable by desktopuser after chmod. Check permissions on server."
    exit 1
fi
echo "Unlock verified — desktopuser can write to openclaw.json"

# Remote scripts are copied by the CI workflow (scp -r scripts → /tmp/)
# They live at /tmp/linux-desktop-setup/scripts/remote/ on the server (Layer 2 source).

# Loop through each repo
for REPO_FULL in $(echo "$TARGET_REPOS" | jq -r '.[]'); do
    echo "=========================================="
    echo "Processing repo: $REPO_FULL"
    echo "=========================================="

    # Parse owner/repo from format: owner/repo
    TARGET_OWNER=$(echo "$REPO_FULL" | cut -d'/' -f1)
    TARGET_REPO=$(echo "$REPO_FULL" | cut -d'/' -f2)
    echo "Target: $TARGET_OWNER/$TARGET_REPO"

    # Fetch channel ID from target repo variable
    CHANNEL_VAR="OPENCLAW_${TARGET_ENV^^}_DISCORD_CHANNEL"
    echo "Fetching $CHANNEL_VAR from $TARGET_OWNER/$TARGET_REPO..."

    CHANNEL_ID=$(GH_TOKEN="$VM_GITHUB_TOKEN" gh api "repos/$TARGET_OWNER/$TARGET_REPO/actions/variables" \
        --jq ".variables[] | select(.name == \"$CHANNEL_VAR\") | .value")
    if [ -z "$CHANNEL_ID" ]; then
        echo "WARNING: No channel variable found for $TARGET_REPO in environment $TARGET_ENV - skipping"
        continue
    fi
    echo "Found channel: $CHANNEL_ID"

    # Collect channel IDs for guild config update
    # Only collect if not already in the list
    if ! echo "$ALL_CHANNEL_IDS" | grep -q "\"$CHANNEL_ID\""; then
        if [ -z "$ALL_CHANNEL_IDS" ]; then
            ALL_CHANNEL_IDS="\"$CHANNEL_ID\""
        else
            ALL_CHANNEL_IDS="$ALL_CHANNEL_IDS \"$CHANNEL_ID\""
        fi
    fi

    # Ensure repo is cloned/updated on the server
    echo "Ensuring repo is available on server: $TARGET_OWNER/$TARGET_REPO..."
    ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@$SERVER_IP \
        "VM_GITHUB_TOKEN=$VM_GITHUB_TOKEN bash /tmp/linux-desktop-setup/scripts/remote/ensure-repo.sh '$TARGET_OWNER' '$TARGET_REPO'"

    # Add agent and binding via openclaw CLI on the server
    echo "Adding OpenClaw agent and binding for $TARGET_REPO..."
    ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@$SERVER_IP \
        "bash /tmp/linux-desktop-setup/scripts/remote/configure-openclaw-agent.sh '$TARGET_REPO' '$CHANNEL_ID'"

    echo "Completed processing: $REPO_FULL"
done

# Update Discord bot token in systemd override.conf on server
echo "=========================================="
echo "Updating Discord bot token in systemd override..."
echo "=========================================="

if [ -z "$DISCORD_BOT_TOKEN" ]; then
    echo "ERROR: DISCORD_BOT_TOKEN is not set - cannot update token"
    exit 1
fi

ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@$SERVER_IP \
    "DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN bash /tmp/linux-desktop-setup/scripts/remote/update-discord-token.sh"

# Add all collected channels to the guilds config so the bot listens on them
# The bindings tell WHICH AGENT to route to, but guilds.channels tells the bot WHICH CHANNELS to listen on
if [ -n "$ALL_CHANNEL_IDS" ]; then
    echo "=========================================="
    echo "Updating guilds channels config..."
    echo "=========================================="

    # Re-unlock config file — inner scripts (configure-openclaw-agent.sh) may have re-locked it to 444
    # Python script runs as desktopuser, need 666 not 644
    ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@$SERVER_IP \
        "chmod 666 /home/desktopuser/.openclaw/openclaw.json && ls -la /home/desktopuser/.openclaw/openclaw.json"

    # Copy Python script to server
    scp -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 scripts/openclaw-update-guilds.py root@$SERVER_IP:/tmp/openclaw-update-guilds.py

    GUILD_ID="${DISCORD_GUILD_ID:-1485047825967480862}"
    CONFIG_FILE="/home/desktopuser/.openclaw/openclaw.json"

    # Build channel IDs as separate args
    CHANNEL_ARGS=""
    for ch in $ALL_CHANNEL_IDS; do
        ch_clean="${ch//\"/}"
        CHANNEL_ARGS="$CHANNEL_ARGS $ch_clean"
    done

    # Run Python script with command-line args (avoids all quoting issues)
    # Note: allowFrom and users are managed by deploy.yml via /tmp/config/openclaw-env.json
    ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@$SERVER_IP \
        "sudo -u desktopuser python3 /tmp/openclaw-update-guilds.py \
        \"$CONFIG_FILE\" \"$GUILD_ID\" $CHANNEL_ARGS"
fi

# Reload systemd and restart gateway to pick up new token and channels
# NOTE: Only restart if gateway is already running; deploy workflow handles
# the initial start when doing clean stop-then-restart cycles.
echo "Reloading systemd and updating gateway config..."
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@$SERVER_IP bash <<'RESTART_SCRIPT'
    set -e
    # Always reload systemd to pick up new override.conf
    sudo -u desktopuser XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload
    # Only restart if already active; otherwise caller (deploy workflow) starts it
    if sudo -u desktopuser XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active --quiet openclaw-gateway.service 2>/dev/null; then
        sudo -u desktopuser XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart openclaw-gateway.service
        echo "Gateway restarted (was active)"
    else
        echo "Gateway not active; skipping restart (deploy workflow will start it)"
    fi
RESTART_SCRIPT

# Clean up temp scripts
# Clean up temp scripts (only those we copied directly, not the CI-copied ones)
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@$SERVER_IP \
    "rm -f /tmp/openclaw-update-guilds.py"

# Re-lock config file after all edits
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@$SERVER_IP "chmod 444 /home/desktopuser/.openclaw/openclaw.json" 2>/dev/null || true

echo "All OpenClaw bindings processed"
