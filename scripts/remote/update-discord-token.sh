#!/bin/bash
set -euo pipefail

# Update OpenClaw secrets in the systemd user-service override.conf.
# All secrets are injected via systemd Environment= so that OpenClaw
# can resolve SecretRefs against the process environment at runtime.
#
# Usage: bash update-discord-token.sh
# Requires env (or persisted on VM in override.conf):
#   DISCORD_BOT_TOKEN          - Discord bot token
#   OPENROUTER_API_KEY         - OpenRouter API key (optional)
#   GATEWAY_AUTH_TOKEN         - Gateway auth token; persisted per-VM
#                                 (read from override.conf if absent in env)
#
# GATEWAY_AUTH_TOKEN is the auth token the gateway uses for
# /health, /tools, and other RPC endpoints. It is referenced from
# openclaw.json as a SecretRef:
#   gateway.auth.token = { source: env, provider: env, id: GATEWAY_AUTH_TOKEN }
# (see PR #747 in the openclaw-gateway repo). If the env var is
# not set when the gateway starts, the SecretRef fails to resolve
# and the gateway exits 1 with
#   SecretRefResolutionError: Environment variable "GATEWAY_AUTH_TOKEN" is missing or empty.
# which the systemd StartLimitBurst=3/300s rate-limits within
# minutes (2026-06-10 incident, job 80470710967).
#
# To make the token survive deploys without putting it in CI secrets,
# the script reads any existing GATEWAY_AUTH_TOKEN from override.conf
# before generating a new one. This means: the first deploy on a
# fresh VM mints a token; subsequent deploys reuse the same one
# (clients, smoke tests, and any external integrations are not
# invalidated by routine redeploys).

OVERRIDE_FILE="/home/desktopuser/.config/systemd/user/openclaw-gateway.service.d/override.conf"
TARGET_USER="desktopuser"

if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then
    echo "ERROR: DISCORD_BOT_TOKEN environment variable is not set"
    exit 1
fi

# GATEWAY_AUTH_TOKEN: read existing from override.conf if not in env.
# Generate a new one only on first deploy.
if [ -z "${GATEWAY_AUTH_TOKEN:-}" ] && [ -f "$OVERRIDE_FILE" ]; then
    EXISTING_TOKEN="$(grep '^Environment=GATEWAY_AUTH_TOKEN=' "$OVERRIDE_FILE" 2>/dev/null | head -1 | cut -d= -f3- || true)"
    if [ -n "$EXISTING_TOKEN" ]; then
        GATEWAY_AUTH_TOKEN="$EXISTING_TOKEN"
        echo "Reusing existing GATEWAY_AUTH_TOKEN from $OVERRIDE_FILE"
    fi
fi
if [ -z "${GATEWAY_AUTH_TOKEN:-}" ]; then
    GATEWAY_AUTH_TOKEN="$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | xxd -p -c 64)"
    echo "Generated new GATEWAY_AUTH_TOKEN (length: ${#GATEWAY_AUTH_TOKEN})"
fi
export GATEWAY_AUTH_TOKEN

echo "Updating secrets in $OVERRIDE_FILE"

mkdir -p "$(dirname "$OVERRIDE_FILE")"

USER_ID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

# Rebuild the override file entirely so stale entries are removed on each deploy.
# OPENROUTER_API_KEY is optional — only include if set.
OPENROUTER_LINE=""
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    OPENROUTER_LINE="Environment=OPENROUTER_API_KEY=${OPENROUTER_API_KEY}"
fi

cat > "$OVERRIDE_FILE" << EOF
[Service]
Environment=DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}
${OPENROUTER_LINE}
Environment=GATEWAY_AUTH_TOKEN=${GATEWAY_AUTH_TOKEN}
Environment=HOME=${TARGET_HOME}
Environment=XDG_RUNTIME_DIR=/run/user/${USER_ID}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/desktopuser/.local/bin:/home/desktopuser/.npm-global/bin
Environment=OPENCLAW_NO_RESPAWN=1
Environment=NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
EOF

chmod 600 "$OVERRIDE_FILE"

echo "Secrets updated in $OVERRIDE_FILE"

# Reload systemd and restart gateway
echo "Reloading systemd and restarting gateway..."
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/${USER_ID}" systemctl --user daemon-reload
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/${USER_ID}" systemctl --user restart openclaw-gateway.service

echo "Gateway restarted with updated secrets"
