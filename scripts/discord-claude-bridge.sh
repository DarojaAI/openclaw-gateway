#!/bin/bash
# discord-claude-bridge.sh - Bridge Discord messages to Claude Code CLI
# Reads OpenCLAW bindings to route channels to repos
# Uses Claude Code Router (ccr) for API routing with per-repo keys

set -euo pipefail

# Configuration
# Check both root and desktopuser paths
if [[ -f "/home/desktopuser/.openclaw/openclaw.json" ]]; then
    OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-/home/desktopuser/.openclaw/openclaw.json}"
else
    OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
fi
CCR_URL="${CCR_URL:-http://127.0.0.1:3456}"
LOG_FILE="${LOG_FILE:-$HOME/.claude-discord-bridge.log}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log_info() { log "INFO: $*"; echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { log "WARN: $*"; echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { log "ERROR: $*"; echo -e "${RED}[ERROR]${NC} $*"; }

# Load config
load_config() {
    if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
        log_error "OpenCLAW config not found: $OPENCLAW_CONFIG"
        exit 1
    fi

    # Get Discord token
    DISCORD_TOKEN=$(jq -r '.channels.discord.token' "$OPENCLAW_CONFIG" 2>/dev/null || true)
    if [[ -z "$DISCORD_TOKEN" || "$DISCORD_TOKEN" == "null" ]]; then
        log_error "Discord token not found in config"
        exit 1
    fi

    # Get bindings
    BINDINGS=$(jq -c '.bindings // []' "$OPENCLAW_CONFIG" 2>/dev/null || echo "[]")

    log_info "Config loaded: $(echo "$BINDINGS" | jq 'length') bindings"
}

# Find workspace for a channel
find_workspace() {
    local channel_id="$1"
    local binding

    binding=$(echo "$BINDINGS" | jq -c ".[] | select(.match.channel == \"discord\" and .match.accountId == \"$channel_id\")" 2>/dev/null || true)

    if [[ -n "$binding" && "$binding" != "null" ]]; then
        echo "$binding" | jq -r '.workspace'
    else
        echo ""
    fi
}

# Find workspace name for a channel
find_workspace_name() {
    local channel_id="$1"
    local binding

    binding=$(echo "$BINDINGS" | jq -c ".[] | select(.match.channel == \"discord\" and .match.accountId == \"$channel_id\")" 2>/dev/null || true)

    if [[ -n "$binding" && "$binding" != "null" ]]; then
        echo "$binding" | jq -r '.workspaceName'
    else
        echo ""
    fi
}

# Get API key for workspace (from auth-profiles.json)
get_api_key() {
    local workspace="$1"
    local agent_id

    # Try to find agent ID from bindings
    agent_id=$(echo "$BINDINGS" | jq -r ".[] | select(.workspace == \"$workspace\") | .agentId" 2>/dev/null || true)

    if [[ -n "$agent_id" && "$agent_id" != "null" ]]; then
        # Check root openclaw
        local auth_file="$HOME/.openclaw/agents/$agent_id/agent/auth-profiles.json"
        if [[ -f "$auth_file" ]]; then
            jq -r '.profiles["openrouter:default"].key // empty' "$auth_file" 2>/dev/null || true
            return
        fi
        # Check desktopuser openclaw
        auth_file="/home/desktopuser/.openclaw/agents/$agent_id/agent/auth-profiles.json"
        if [[ -f "$auth_file" ]]; then
            jq -r '.profiles["openrouter:default"].key // empty' "$auth_file" 2>/dev/null || true
            return
        fi
    fi

    # Fallback to env var
    echo "${OPENROUTER_API_KEY:-}"
}

# Send message to Discord
discord_send() {
    local channel_id="$1"
    local message="$2"

    # Escape message for JSON
    local escaped_message
    escaped_message=$(echo "$message" | jq -Rs '.')

    curl -s -X POST "https://discord.com/api/v10/channels/$channel_id/messages" \
        -H "Authorization: Bot $DISCORD_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"content\": $escaped_message}" >> "$LOG_FILE" 2>&1
}

# Process message with Claude via OpenRouter API
claude_query() {
    local workspace="$1"
    local message="$2"
    local api_key="$3"

    # Change to workspace directory (for context)
    if [[ -n "$workspace" && -d "$workspace" ]]; then
        cd "$workspace" || return 1
    fi

    # Use API key from auth or fallback to env/default
    local key="$api_key"
    if [[ -z "$key" ]]; then
        key="${OPENROUTER_API_KEY:-}"
    fi
    if [[ -z "$key" ]]; then
        echo "Error: No API key available"
        return 1
    fi

    # Call OpenRouter API directly (bypassing CLI login issues)
    local response
    response=$(curl -s https://openrouter.ai/api/v1/chat/completions \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -H "HTTP-Referer: https://github.com/patelmm79/bond-nexus" \
        -H "X-Title: bond-nexus" \
        -d "{
            \"model\": \"anthropic/claude-sonnet-4-6\",
            \"messages\": [{\"role\": \"user\", \"content\": \"$message\"}],
            \"max_tokens\": 4096
        }" 2>&1)

    # Extract content from response
    echo "$response" | jq -r '.choices[0].message.content // .error.message // "Error: No response"' 2>&1
}

# Process a Discord message
process_message() {
    local channel_id="$1"
    local message_id="$2"
    local message_content="$3"
    local author_id="$4"

    log "Processing message $message_id from channel $channel_id"

    # Find workspace for this channel
    local workspace
    workspace=$(find_workspace "$channel_id")

    local workspace_name
    workspace_name=$(find_workspace_name "$channel_id")

    if [[ -z "$workspace" ]]; then
        log_warn "No binding found for channel $channel_id"
        return 0
    fi

    log_info "Routing to workspace: $workspace ($workspace_name)"

    # Get API key for this workspace
    local api_key
    api_key=$(get_api_key "$workspace")

    # Send "thinking" reaction to show we're processing
    # discord_react "$channel_id" "$message_id" "thinking"

    # Process with Claude
    local response
    if response=$(claude_query "$workspace" "$message_content" "$api_key"); then
        # Send response (truncate if too long for Discord)
        if [[ ${#response} -gt 1900 ]]; then
            response="${response:0:1900}\n\n...(truncated)"
        fi

        # Send in chunks if needed
        echo -e "$response" | while read -r line; do
            if [[ ${#line} -gt 1900 ]]; then
                # Split long lines
                echo "$line" | fold -w 1900 | while read -r chunk; do
                    discord_send "$channel_id" "$chunk"
                done
            else
                discord_send "$channel_id" "$line"
            fi
        done

        log_info "Response sent to channel $channel_id"
    else
        discord_send "$channel_id" "❌ Error processing your request. Check logs for details."
        log_error "Claude query failed for workspace $workspace"
    fi
}

# Poll for new messages (simple version - production would use webhooks)
poll_messages() {
    local last_message_id="${1:-}"
    local channel_id="$2"

    local url="https://discord.com/api/v10/channels/$channel_id/messages"
    if [[ -n "$last_message_id" ]]; then
        url="$url?after=$last_message_id"
    fi

    curl -s "$url" -H "Authorization: Bot $DISCORD_TOKEN" 2>/dev/null | jq -r '.[] | "\(.id)|\(.content)|\(.author.id)"' 2>/dev/null || true
}

# Main: Listen to a specific channel (for testing)
main() {
    local test_channel="${1:-1487986866832805888}"  # bond-nexus default

    log_info "Starting Discord-Claude bridge..."
    log_info "Test channel: $test_channel"

    load_config

    log_info "Bridge ready. Listening to channel $test_channel"

    local last_message_id=""

    while true; do
        local messages
        messages=$(poll_messages "$last_message_id" "$test_channel")

        if [[ -n "$messages" ]]; then
            while IFS='|' read -r msg_id content author; do
                if [[ -n "$msg_id" && -n "$content" && ! "$content" =~ ^[[:space:]]*$ ]]; then
                    # Skip bot messages
                    if [[ "$author" != "147918627249807361" ]]; then  # Bot user ID check
                        log "Received: $content"
                        process_message "$test_channel" "$msg_id" "$content" "$author"
                    fi
                fi
                last_message_id="$msg_id"
            done <<< "$messages"
        fi

        sleep 2  # Poll every 2 seconds
    done
}

# Usage
usage() {
    echo "Usage: $0 [channel_id]"
    echo "  channel_id: Discord channel ID to listen to (default: bond-nexus)"
    echo ""
    echo "Environment variables:"
    echo "  OPENCLAW_CONFIG  - Path to OpenCLAW config (default: ~/.openclaw/openclaw.json)"
    echo "  CCR_URL          - Claude Code Router URL (default: http://127.0.0.1:3456)"
    echo "  LOG_FILE         - Log file path"
    exit 1
}

# Run
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

main "$@"