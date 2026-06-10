#!/usr/bin/env bats
#
# tests/viz-service-installer.bats
#
# Tests for scripts/services/install-viz-service.sh
#
# The installer is the only thing that wires the viz service into a host.
# It must:
#   1. Copy the service code to ~/.openclaw/services/viz/
#   2. Install npm dependencies
#   3. Copy the skill to ~/.openclaw/skills/viz/
#   4. Symlink the systemd unit into ~/.config/systemd/user/
#   5. (When systemd is available) enable and start the service
#
# All tests use a sandboxed HOME so they don't pollute the real install.
# Tests run in <1s each; no playwright, no chromium, no network.
#
# Test cases:
#   1. copies service code to destination
#   2. installs npm dependencies
#   3. copies the skill to ~/.openclaw/skills/viz/SKILL.md
#   4. creates a symlink for the systemd unit
#   5. unit symlink target is the repo file (idempotent on re-run)
#   6. installer is idempotent — second run doesn't fail
#   7. fails clearly if source dir is missing

setup() {
  # Sandbox HOME so we don't touch the real ~/.openclaw
  export TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export XDG_CONFIG_HOME="$TEST_HOME/.config"
  mkdir -p "$TEST_HOME"

  # Find the repo root (BATS test files run from the repo root)
  REPO_ROOT="$(pwd)"
  export REPO_ROOT
}

teardown() {
  rm -rf "$TEST_HOME"
}

@test "viz installer: copies service code to destination" {
  run bash scripts/services/install-viz-service.sh
  [ "$status" -eq 0 ]
  [ -f "$HOME/.openclaw/services/viz/render-server.js" ]
  [ -f "$HOME/.openclaw/services/viz/render-cli.js" ]
  [ -f "$HOME/.openclaw/services/viz/discord-viz.js" ]
  [ -f "$HOME/.openclaw/services/viz/package.json" ]
}

@test "viz installer: installs npm dependencies" {
  run bash scripts/services/install-viz-service.sh
  [ "$status" -eq 0 ]
  [ -d "$HOME/.openclaw/services/viz/node_modules" ]
  # Verify express is installed (it's a required dep)
  [ -d "$HOME/.openclaw/services/viz/node_modules/express" ]
  # Verify playwright is installed (required for rendering)
  [ -d "$HOME/.openclaw/services/viz/node_modules/playwright" ]
}

@test "viz installer: copies skill to ~/.openclaw/skills/viz/SKILL.md" {
  run bash scripts/services/install-viz-service.sh
  [ "$status" -eq 0 ]
  [ -f "$HOME/.openclaw/skills/viz/SKILL.md" ]
  # Skill must have the right frontmatter so OpenClaw auto-loads it
  run head -1 "$HOME/.openclaw/skills/viz/SKILL.md"
  [[ "$output" == "---" ]]
  grep -q "^name: viz" "$HOME/.openclaw/skills/viz/SKILL.md"
}

@test "viz installer: creates a symlink for the systemd unit" {
  run bash scripts/services/install-viz-service.sh
  [ "$status" -eq 0 ]
  [ -L "$HOME/.config/systemd/user/openclaw-viz.service" ]
}

@test "viz installer: unit symlink target is the repo file" {
  run bash scripts/services/install-viz-service.sh
  [ "$status" -eq 0 ]
  local target
  target=$(readlink "$HOME/.config/systemd/user/openclaw-viz.service")
  [ -f "$target" ]
  # Source must have the right [Unit] section
  grep -q "Description=OpenClaw Shared Viz Service" "$target"
  grep -q "Before=openclaw-gateway.service" "$target"
  grep -q "PartOf=openclaw-gateway.service" "$target"
}

@test "viz installer: idempotent on re-run" {
  bash scripts/services/install-viz-service.sh
  local first_pid
  first_pid=$(cat "$HOME/.openclaw/services/viz/.server.pid" 2>/dev/null || echo "")
  # Second run must not fail (this is the contract for re-deploys)
  run bash scripts/services/install-viz-service.sh
  [ "$status" -eq 0 ]
  # The service files should still all be present
  [ -f "$HOME/.openclaw/services/viz/render-server.js" ]
  [ -L "$HOME/.config/systemd/user/openclaw-viz.service" ]
}

@test "viz installer: fails clearly if source dir is missing" {
  # Set VIZ_SERVICE_DIR and temporarily move the source dir to simulate
  # a broken clone. The installer should fail with a clear error.
  local bak="$REPO_ROOT/config/services/viz.bak"
  mv "$REPO_ROOT/config/services/viz" "$bak"
  run bash scripts/services/install-viz-service.sh
  echo "STATUS=$status"
  echo "OUTPUT=$output"
  mv "$bak" "$REPO_ROOT/config/services/viz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source dir not found"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "viz service: render-server.js is valid Node" {
  # The service must at least parse — no syntax errors allowed.
  # This is a cheap guard against shipping broken code in a release.
  run node --check scripts/../config/services/viz/render-server.js
  [ "$status" -eq 0 ]
}

@test "viz service: discord-viz.js is valid Node" {
  run node --check scripts/../config/services/viz/discord-viz.js
  [ "$status" -eq 0 ]
}

@test "viz service: render-cli.js is valid Node" {
  run node --check scripts/../config/services/viz/render-cli.js
  [ "$status" -eq 0 ]
}

@test "viz unit: has the right lifecycle hooks" {
  # Guards the "Before/PartOf" wiring we promised the gateway
  local unit="etc/systemd/user/openclaw-viz.service"
  [ -f "$unit" ]
  grep -q "^Before=openclaw-gateway.service$" "$unit"
  grep -q "^PartOf=openclaw-gateway.service$" "$unit"
  grep -q "^After=network-online.target$" "$unit"
  # Restart limits match the gateway's (avoid restart storms)
  grep -q "^StartLimitBurst=3$" "$unit"
  grep -q "^StartLimitIntervalSec=300$" "$unit"
  # Uses the same compile cache as the gateway
  grep -q "^Environment=NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache$" "$unit"
}
