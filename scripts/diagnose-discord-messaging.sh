#!/bin/bash
# Diagnostic script for Discord bot messaging failures
# Run this on the test VM or via SSH from CI
# Usage: bash diagnose-discord-messaging.sh [test|head|prod]

set -euo pipefail

TARGET_ENV="${1:-test}"
SSH_KEY="${SSH_KEY:-/c/Users/insan/.ssh/hetznertest.key}"

# Get server IP from terraform output or environment
if [[ -z "${SERVER_IP:-}" ]]; then
    cd terraform 2>/dev/null || true
    SERVER_IP=$(terraform output -raw server_ip 2>/dev/null || echo "")
    cd - >/dev/null 2>&1 || true
fi

if [[ -z "$SERVER_IP" ]]; then
    echo "ERROR: SERVER_IP not set. Provide via environment or terraform output"
    exit 1
fi

echo "=== Discord Messaging Diagnostics: $TARGET_ENV ==="
echo "Server IP: $SERVER_IP"
echo ""

# Function to run SSH commands
run_ssh() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${SERVER_IP}" "$@"
}

# =============================================================================
# CHECK 1: Gateway Status
# =============================================================================
echo "--- CHECK 1: OpenCLAW Gateway Status ---"
GATEWAY_RUNNING=$(run_ssh "pgrep -f 'openclaw gateway' > /dev/null && echo 'running' || echo 'stopped'" 2>/dev/null || echo "error")
if [[ "$GATEWAY_RUNNING" == "running" ]]; then
    echo "✅ Gateway is running"
else
    echo "❌ Gateway is NOT running (status: $GATEWAY_RUNNING)"
    echo "   Check: journalctl --user -u openclaw-gateway.service -n 50"
    echo "   Fix: sudo -u desktopuser systemctl --user restart openclaw-gateway.service"
fi
echo ""

# =============================================================================
# CHECK 2: Discord Bot Token in systemd override
# =============================================================================
echo "--- CHECK 2: Discord Bot Token in systemd override ---"
OVERRIDE_CONTENT=$(run_ssh "cat /home/desktopuser/.config/systemd/user/openclaw-gateway.service.d/override.conf 2>/dev/null" || echo "")
if echo "$OVERRIDE_CONTENT" | grep -q "DISCORD_BOT_TOKEN="; then
    TOKEN_LINE=$(echo "$OVERRIDE_CONTENT" | grep "DISCORD_BOT_TOKEN=")
    if [[ -n "$TOKEN_LINE" ]]; then
        # Check if token is not empty/placeholder
        TOKEN_VALUE=$(echo "$TOKEN_LINE" | cut -d= -f3-)
        if [[ -n "$TOKEN_VALUE" && "$TOKEN_VALUE" != "\${DISCORD_BOT_TOKEN}" && "$TOKEN_VALUE" != "{{"* ]]; then
            echo "✅ DISCORD_BOT_TOKEN is set (length: ${#TOKEN_VALUE})"
        else
            echo "❌ DISCORD_BOT_TOKEN is empty or placeholder: '$TOKEN_VALUE'"
            echo "   Fix: Re-run deployment or manually update token"
        fi
    fi
else
    echo "❌ DISCORD_BOT_TOKEN not found in override.conf"
    echo "   Fix: Run update-discord-token.sh"
fi
echo ""

# =============================================================================
# CHECK 3: Bot in Guild & Permissions
# =============================================================================
echo "--- CHECK 3: Bot Guild Membership & Permissions ---"
BOT_TOKEN=$(echo "$OVERRIDE_CONTENT" | grep "DISCORD_BOT_TOKEN=" | cut -d= -f3-)

if [[ -z "$BOT_TOKEN" ]]; then
    echo "❌ Cannot check guild - no bot token available"
else
    # Check bot is in guild
    GUILD_RESPONSE=$(run_ssh "curl -s -H 'Authorization: Bot $BOT_TOKEN' 'https://discord.com/api/v10/users/@me/guilds'" 2>/dev/null || echo "")
    GUILD_ID="1485047825967480862"
    
    if echo "$GUILD_RESPONSE" | grep -q "\"id\":\"$GUILD_ID\""; then
        echo "✅ Bot is in guild $GUILD_ID"
        
        # Check permissions (simplified check)
        echo "   Checking bot permissions..."
        # This would need the bot's user ID and role checks - simplified for now
        echo "   ℹ️  Verify bot has: VIEW_CHANNEL, SEND_MESSAGES, READ_MESSAGE_HISTORY, USE_APPLICATION_COMMANDS"
    else
        echo "❌ Bot is NOT in guild $GUILD_ID"
        echo "   Fix: Invite bot to guild with proper permissions"
        echo "   Bot response: $GUILD_RESPONSE"
    fi
fi
echo ""

# =============================================================================
# CHECK 4: Guild Channels Configuration
# =============================================================================
echo "--- CHECK 4: Guild Channels in openclaw.json ---"
CONFIG_GUILDS=$(run_ssh "sudo -u desktopuser jq -r '.channels.discord.guilds | keys[]? // empty' /home/desktopuser/.openclaw/openclaw.json 2>/dev/null" || echo "")
if [[ -n "$CONFIG_GUILDS" ]]; then
    echo "✅ Guilds configured: $CONFIG_GUILDS"
    
    # Check channels in guild
    for guild in $CONFIG_GUILDS; do
        CHANNELS=$(run_ssh "sudo -u desktopuser jq -r '.channels.discord.guilds.\"$guild\".channels | keys[]? // empty' /home/desktopuser/.openclaw/openclaw.json 2>/dev/null" || echo "")
        if [[ -n "$CHANNELS" ]]; then
            echo "   Channels in guild $guild: $CHANNELS"
        else
            echo "   ⚠️  No channels configured in guild $guild"
        fi
    done
else
    echo "❌ No guilds configured in openclaw.json"
    echo "   Fix: Run openclaw-update-guilds.py"
fi
echo ""

# =============================================================================
# CHECK 5: Agent Bindings
# =============================================================================
echo "--- CHECK 5: Agent-Channel Bindings ---"
BINDINGS=$(run_ssh "sudo -u desktopuser jq -r '.bindings[]? | \"Agent: \(.agentId) -> Channel: \(.match.peer.id)\"' /home/desktopuser/.openclaw/openclaw.json 2>/dev/null" || echo "")
if [[ -n "$BINDINGS" ]]; then
    echo "✅ Bindings found:"
    echo "$BINDINGS" | while read line; do echo "   $line"; done
else
    echo "❌ No bindings configured"
    echo "   Fix: Run configure-openclaw-agent.sh"
fi
echo ""

# =============================================================================
# CHECK 6: Test Message Send/Receive
# =============================================================================
echo "--- CHECK 6: Test Message Sending ---"
echo "   ℹ️  To test messaging, send a message to the bot's channel in Discord"
echo "   ℹ️  Check gateway logs: journalctl --user -u openclaw-gateway.service -f"
echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo "=== DIAGNOSTIC SUMMARY ==="
echo "Run this to apply fixes:"
echo "  bash scripts/openclaw-bind-repos.sh $SERVER_IP $TARGET_ENV '[\"DarojaAI/linux-desktop-seed\"]'"
echo ""
echo "Then restart gateway:"
echo "  ssh root@$SERVER_IP 'sudo -u desktopuser systemctl --user restart openclaw-gateway.service'"
echo ""
echo "Verify with:"
echo "  bash tests/test-openclaw-channel-enhanced.sh"
