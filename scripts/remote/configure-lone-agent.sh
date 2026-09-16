#!/bin/bash
# configure-lone-agent.sh -- Materialize a "lone" OpenClaw agent on the VM.
#
# What this is for:
#   When dat-contract.yaml's `agent_mcp_bindings` lists an agent that has
#   no matching GitHub repo (gh api repos/<owner>/<repo> returns 404), the
#   bind chain's workspace-bearing path (Phase 3 `ensure_repo.sh` + Phase 4
#   `configure-openclaw-agent.sh`) cannot materialize the agent: there's
#   no `owner/repo` to clone, no `repo_name` to thread into the per-agent
#   dir, and no Discord channel ID to retrieve from
#   OPENCLAW_<ENV>_DISCORD_CHANNEL actions variable.
#
#   A "lone" agent is one whose contract entry has no GitHub anchor.
#   Examples: `ai_governance` is contract-known and configured by Milan,
#   but the agent runs alongside the other agents on the VM rather than
#   backing a GitHub codebase. This script materializes that agent's
#   `~/.openclaw/agents/<agent_id>/agent/agent-config.yaml` directly so
#   the runtime can see it.
#
# What this does NOT do:
#   * No git clone. The agent is not tied to a GitHub codebase.
#   * No MCP server writes. Per-agent MCP bindings are still sourced from
#     `OPENCLAW_AGENT_MCP_BINDINGS` (passed by the deploy workflow and
#     consumed by `post-deploy-verify-provisioning.sh` on the verify
#     side; configure-openclaw-extensions.sh on the bind side). This
#     script only materializes the per-agent config tree; MCP wiring
#     happens during the rest of the bind chain.
#   * No Discord channel ID. Lacking that, the agent runs without a
#     channel binding; downstream steps that REQUIRE a channel ID
#     (e.g. `openclaw-update-guilds.py`) will skip it gracefully.
#
# Usage:
#   bash configure-lone-agent.sh <agent_id>
#
# Requires: OPENCLAW_APP_USER (defaults to `desktopuser`).
# Exit codes:
#   0   agent materialized (or already in expected state).
#   1   mkdir/install failed.
#   2   bad CLI invocation.

set -euo pipefail

AGENT_ID="${1:-}"
if [ -z "$AGENT_ID" ]; then
    echo "ERROR: agent_id is required"
    echo "  usage: $0 <agent_id>"
    exit 2
fi

# Canonical form: lowercase, hyphens→underscores. Mirrors
# configure-openclaw-agent.sh's normalization so the disk path matches
# what `openclaw.json`'s `agents.entries` key would be.
CANONICAL_ID="$(echo "$AGENT_ID" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"

OPENCLAW_DIR="${OPENCLAW_DIR:-/home/desktopuser/.openclaw}"
APP_USER="${OPENCLAW_APP_USER:-desktopuser}"
AGENT_DIR="${AGENT_DIR:-$OPENCLAW_DIR/agents/$CANONICAL_ID}"
CONFIG_FILE="${CONFIG_FILE:-$AGENT_DIR/agent/agent-config.yaml}"

if [ -f "$CONFIG_FILE" ]; then
    echo "[SKIP] $CANONICAL_ID — agent-config.yaml already exists at $CONFIG_FILE"
    exit 0
fi

mkdir -p "$AGENT_DIR/agent"

# Minimal agent-config.yaml. Matches the schema used by the
# workspace-bearing agents (handle, role, capabilities, skills,
# allowed_channels). Caller can override later via the runtime's
# `agents.update` shape; this script just bootstraps the file so the
# gateway's startup scan sees the agent.
cat > "$CONFIG_FILE" <<YAML
handle: "@$CANONICAL_ID"
contract_version: "v1"
role: "executor"
capabilities:
  - "lone-agent"
allowed_channels: []
skills:
  - "model-preferences"
  - "model-management"
YAML

# Owner/permissions hygiene: agents.<id>/agent/agent-config.yaml is the
# canonical read surface for the gateway, owned by the app user, mode
# 0644. Matches the convention configure-openclaw-agent.sh uses after
# a workspace clone.
chown "$APP_USER:$APP_USER" "$AGENT_DIR" "$AGENT_DIR/agent" "$CONFIG_FILE" 2>/dev/null || \
    echo "WARN: chown $CONFIG_FILE failed (non-root?); ownership unchanged"
chmod 0644 "$CONFIG_FILE"

echo "[OK] $CANONICAL_ID — agent-config.yaml bootstrapped at $CONFIG_FILE"
