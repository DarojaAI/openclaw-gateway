#!/bin/bash
# Install/deploy the shared viz service from this repo to ~/.openclaw/services/viz/
# Usage: bash scripts/services/install-viz-service.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_DIR="$REPO_ROOT/config/services/viz"
DEST_DIR="${VIZ_SERVICE_DIR:-$HOME/.openclaw/services/viz}"

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: source dir not found: $SRC_DIR" >&2
  exit 1
fi

echo "Installing viz service:"
echo "  source: $SRC_DIR"
echo "  target: $DEST_DIR"

mkdir -p "$DEST_DIR"

# Copy service files (preserve anything the user has in cache/, logs/, etc.)
for f in render-server.js render-cli.js discord-viz.js package.json package-lock.json README.md; do
  if [ -f "$SRC_DIR/$f" ]; then
    cp "$SRC_DIR/$f" "$DEST_DIR/$f"
  fi
done

cd "$DEST_DIR"
if [ ! -d node_modules ] || [ package.json -nt node_modules ]; then
  if command -v npm >/dev/null 2>&1; then
    echo "Installing dependencies..."
    npm install --silent
  else
    echo "WARN: npm not found on PATH - skipping dependency install." >&2
    echo "      The viz service will not start until node + npm are installed and 'npm install' is run in $DEST_DIR." >&2
    echo "      To enable: install nodejs (e.g. apt install nodejs npm) and re-run this script." >&2
  fi
fi

# Copy skill
SKILL_SRC="$REPO_ROOT/config/skills/viz/SKILL.md"
SKILL_DST="$HOME/.openclaw/skills/viz/SKILL.md"
if [ -f "$SKILL_SRC" ]; then
  mkdir -p "$(dirname "$SKILL_DST")"
  cp "$SKILL_SRC" "$SKILL_DST"
  echo "Skill installed at: $SKILL_DST"
fi

# Install systemd user unit (idempotent — symlink so updates flow through)
UNIT_SRC="$REPO_ROOT/etc/systemd/user/openclaw-viz.service"
UNIT_DST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_DST="$UNIT_DST_DIR/openclaw-viz.service"
if [ -f "$UNIT_SRC" ]; then
  mkdir -p "$UNIT_DST_DIR"
  ln -sf "$UNIT_SRC" "$UNIT_DST"
  echo "Systemd unit installed at: $UNIT_DST"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
    if ! command -v node >/dev/null 2>&1; then
      echo "WARN: /usr/bin/node not found - skipping systemd service start." >&2
      echo "      Install nodejs, then 'systemctl --user start openclaw-viz'." >&2
    else
      if systemctl --user is-enabled openclaw-viz >/dev/null 2>&1; then
        echo "Service already enabled; reloading config"
      else
        systemctl --user enable openclaw-viz 2>/dev/null && echo "Service enabled (autostart on login)" || echo "WARN: could not enable service" >&2
      fi
      if systemctl --user is-active openclaw-viz >/dev/null 2>&1; then
        systemctl --user restart openclaw-viz && echo "Service restarted" || echo "WARN: could not restart service" >&2
      else
        systemctl --user start openclaw-viz && echo "Service started" || echo "WARN: could not start service (node missing or other issue)" >&2
      fi
    fi
  fi
fi

echo ""
echo "✓ Viz service installed at $DEST_DIR"
echo ""
echo "Usage from any agent:"
echo "  const viz = require('$DEST_DIR/discord-viz');"
echo "  const pngPath = await viz.renderMermaid('graph TD; A-->B');"
echo ""
echo "Service management:"
echo "  systemctl --user status openclaw-viz"
echo "  systemctl --user restart openclaw-viz"
echo "  journalctl --user -u openclaw-viz -f"
