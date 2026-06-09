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
  echo "Installing dependencies..."
  npm install --silent
fi

# Copy skill
SKILL_SRC="$REPO_ROOT/config/skills/viz/SKILL.md"
SKILL_DST="$HOME/.openclaw/skills/viz/SKILL.md"
if [ -f "$SKILL_SRC" ]; then
  mkdir -p "$(dirname "$SKILL_DST")"
  cp "$SKILL_SRC" "$SKILL_DST"
  echo "Skill installed at: $SKILL_DST"
fi

echo ""
echo "✓ Viz service installed at $DEST_DIR"
echo ""
echo "Usage from any agent:"
echo "  const viz = require('$DEST_DIR/discord-viz');"
echo "  const pngPath = await viz.renderMermaid('graph TD; A-->B');"
echo ""
echo "To start the server now:"
echo "  node $DEST_DIR/render-server.js &"
