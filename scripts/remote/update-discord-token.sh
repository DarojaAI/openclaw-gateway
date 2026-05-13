#!/bin/bash
set -euo pipefail

# Update Discord bot token in the OpenClaw systemd override.conf
# Usage: bash update-discord-token.sh
# Requires DISCORD_BOT_TOKEN env var to be set.

OVERRIDE_FILE="/home/desktopuser/.config/systemd/user/openclaw-gateway.service.d/override.conf"
TARGET_USER="desktopuser"

if [ -z "$DISCORD_BOT_TOKEN" ]; then
    echo "ERROR: DISCORD_BOT_TOKEN environment variable is not set"
    exit 1
fi

echo "Updating Discord bot token in $OVERRIDE_FILE"

# Ensure directory exists
mkdir -p "$(dirname "$OVERRIDE_FILE")"

# Create or update the override.conf
if [ -f "$OVERRIDE_FILE" ]; then
    # Update existing token line or add it
    if grep -q "DISCORD_BOT_TOKEN=" "$OVERRIDE_FILE"; then
        sed -i "s|Environment=DISCORD_BOT_TOKEN=.*|Environment=DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}|" "$OVERRIDE_FILE"
    else
        echo "Environment=DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}" >> "$OVERRIDE_FILE"
    fi
else
    # Get user ID for XDG_RUNTIME_DIR
    USER_ID=$(id -u "$TARGET_USER")
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

    cat > "$OVERRIDE_FILE" << EOF
[Service]
Environment=DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}
Environment=HOME=${TARGET_HOME}
Environment=XDG_RUNTIME_DIR=/run/user/${USER_ID}
EOF
fi

echo "Discord bot token updated in $OVERRIDE_FILE"

# Reload systemd and restart gateway
echo "Reloading systemd and restarting gateway..."
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$(id -u "$TARGET_USER") systemctl --user daemon-reload
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$(id -u "$TARGET_USER") systemctl --user restart openclaw-gateway.service

echo "Gateway restarted with new Discord bot token"