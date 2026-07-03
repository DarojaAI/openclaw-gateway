#!/usr/bin/env bats
# tests/merge-agents-lock.bats
#
# BATS tests for scripts/ci/merge-agents-lock.py
#
# Validates that:
# 1. Single fragment produces correct TOML
# 2. Multiple fragments are merged without collisions
# 3. Duplicate slug causes error
# 4. Missing fragments dir causes error
# 5. Empty fragments dir causes error
# 6. Output contains schema_version

setup() {
  FRAGMENTS_DIR=$(mktemp -d /tmp/lockfile-fragments-XXXX)
  OUTPUT_FILE=$(mktemp /tmp/agents-lock-XXXX.toml)
}

teardown() {
  rm -rf "$FRAGMENTS_DIR"
  rm -f "$OUTPUT_FILE"
}

@test "single fragment produces correct TOML" {
  cat > "$FRAGMENTS_DIR/linux-desktop-seed.toml" << 'EOF'
[agents.linux-desktop-seed]
repo = "DarojaAI/linux-desktop-seed"
handle = "@linux-desktop-seed"
contract_version = "1"
config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"
config_sha = "abc1234567890abcdef1234567890abcdef123456"
last_deploy_at = "2026-07-03T18:30:00Z"
EOF

  run python3 scripts/ci/merge-agents-lock.py --fragments-dir "$FRAGMENTS_DIR" --output "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  grep -q 'schema_version = "1"' "$OUTPUT_FILE"
  grep -qF '[agents.linux-desktop-seed]' "$OUTPUT_FILE"
  grep -q 'repo = "DarojaAI/linux-desktop-seed"' "$OUTPUT_FILE"
}

@test "multiple fragments are merged without collisions" {
  cat > "$FRAGMENTS_DIR/linux-desktop-seed.toml" << 'EOF'
[agents.linux-desktop-seed]
repo = "DarojaAI/linux-desktop-seed"
handle = "@linux-desktop-seed"
contract_version = "1"
config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"
config_sha = "abc1234567890abcdef1234567890abcdef123456"
last_deploy_at = "2026-07-03T18:30:00Z"
EOF

  cat > "$FRAGMENTS_DIR/openclaw-agent.toml" << 'EOF'
[agents.openclaw-agent]
repo = "DarojaAI/openclaw-agent"
handle = "@openclaw-agent"
contract_version = "2"
config_source = "https://github.com/DarojaAI/openclaw-agent/blob/main/.openclaw/agent-config.yaml"
config_sha = "def1234567890abcdef1234567890abcdef123456"
last_deploy_at = "2026-07-03T18:35:00Z"
EOF

  run python3 scripts/ci/merge-agents-lock.py --fragments-dir "$FRAGMENTS_DIR" --output "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  grep -qF '[agents.linux-desktop-seed]' "$OUTPUT_FILE"
  grep -qF '[agents.openclaw-agent]' "$OUTPUT_FILE"
  grep -q 'repo = "DarojaAI/linux-desktop-seed"' "$OUTPUT_FILE"
  grep -q 'repo = "DarojaAI/openclaw-agent"' "$OUTPUT_FILE"
}

@test "duplicate slug causes error" {
  cat > "$FRAGMENTS_DIR/frag-1.toml" << 'EOF'
[agents.linux-desktop-seed]
repo = "DarojaAI/linux-desktop-seed"
handle = "@linux-desktop-seed"
contract_version = "1"
config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"
config_sha = "abc1234567890abcdef1234567890abcdef123456"
EOF

  cat > "$FRAGMENTS_DIR/frag-2.toml" << 'EOF'
[agents.linux-desktop-seed]
repo = "DarojaAI/linux-desktop-seed"
handle = "@linux-desktop-seed"
contract_version = "2"
config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"
config_sha = "def1234567890abcdef1234567890abcdef123456"
EOF

  run python3 scripts/ci/merge-agents-lock.py --fragments-dir "$FRAGMENTS_DIR" --output "$OUTPUT_FILE"
  [ "$status" -eq 2 ]
}

@test "missing fragments dir causes error" {
  run python3 scripts/ci/merge-agents-lock.py --fragments-dir "/nonexistent-dir" --output "$OUTPUT_FILE"
  [ "$status" -eq 2 ]
}

@test "empty fragments dir causes error" {
  # FRAGMENTS_DIR is created by setup() but empty
  run python3 scripts/ci/merge-agents-lock.py --fragments-dir "$FRAGMENTS_DIR" --output "$OUTPUT_FILE"
  [ "$status" -eq 2 ]
}

@test "output contains schema_version" {
  cat > "$FRAGMENTS_DIR/linux-desktop-seed.toml" << 'EOF'
[agents.linux-desktop-seed]
repo = "DarojaAI/linux-desktop-seed"
handle = "@linux-desktop-seed"
contract_version = "1"
config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"
config_sha = "abc1234567890abcdef1234567890abcdef123456"
last_deploy_at = "2026-07-03T18:30:00Z"
EOF

  run python3 scripts/ci/merge-agents-lock.py --fragments-dir "$FRAGMENTS_DIR" --output "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  grep -q 'schema_version = "1"' "$OUTPUT_FILE"
}
