#!/usr/bin/env bats
#
# tests/gateway-agents-command.bats
#
# Tests for scripts/openclaw-gateway-agents.py and its shell wrapper.
#

setup() {
  export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
  export PYTHON_SCRIPT="${REPO_ROOT}/scripts/openclaw-gateway-agents.py"
  export SHELL_WRAPPER="${REPO_ROOT}/scripts/openclaw-gateway-agents.sh"
  TMPDIR="${BATS_TMPDIR}/gateway-agents-$$"
  mkdir -p "${TMPDIR}"
}

# ── Python script tests ──────────────────────────────────────────────

@test "table output with 2 agents" {
  cat > "${TMPDIR}/agents.lock.toml" <<'EOF'
schema_version = "1"

[agents.alpha]
repo             = "DarojaAI/alpha"
handle           = "@alpha"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/alpha/blob/main/.openclaw/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

[agents.beta]
repo             = "DarojaAI/beta"
handle           = "@beta"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/beta/blob/main/.openclaw/agent-config.yaml"
config_sha       = "f0e1d2c3b4a5f0e1d2c3b4a5f0e1d2c3b4a5f0e1"
EOF

  run python3 "${PYTHON_SCRIPT}" "${TMPDIR}/agents.lock.toml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"alpha"* ]]
  [[ "${output}" == *"beta"* ]]
  [[ "${output}" == *"2 agent(s) registered"* ]]
}

@test "table output includes handle, repo columns" {
  cat > "${TMPDIR}/agents.lock.toml" <<'EOF'
schema_version = "1"

[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@linux-desktop-seed"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
EOF

  run python3 "${PYTHON_SCRIPT}" "${TMPDIR}/agents.lock.toml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"Handle"* ]]
  [[ "${output}" == *"Repo"* ]]
  [[ "${output}" == *"@linux-desktop-seed"* ]]
  [[ "${output}" == *"DarojaAI/linux-desktop-seed"* ]]
}

@test "missing lockfile prints message and exits 0" {
  run python3 "${PYTHON_SCRIPT}" "${TMPDIR}/nonexistent.lock.toml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"No agents.lock.toml found"* ]]
}

@test "empty agents section prints message" {
  cat > "${TMPDIR}/empty.lock.toml" <<'EOF'
schema_version = "1"
EOF

  run python3 "${PYTHON_SCRIPT}" "${TMPDIR}/empty.lock.toml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"No agents found"* ]]
}

@test "malformed lockfile returns error" {
  cat > "${TMPDIR}/bad.lock.toml" <<'EOF'
this is not valid toml
{
  "json": "inside a toml file"
}
EOF

  run python3 "${PYTHON_SCRIPT}" "${TMPDIR}/bad.lock.toml"
  [ "$status" -eq 2 ]
}

@test "agents sorted by slug in output" {
  cat > "${TMPDIR}/agents.lock.toml" <<'EOF'
schema_version = "1"

[agents.zulu]
repo             = "DarojaAI/zulu"
handle           = "@zulu"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/zulu/blob/main/.openclaw/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

[agents.alpha]
repo             = "DarojaAI/alpha"
handle           = "@alpha"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/alpha/blob/main/.openclaw/agent-config.yaml"
config_sha       = "f0e1d2c3b4a5f0e1d2c3b4a5f0e1d2c3b4a5f0e1"
EOF

  run python3 "${PYTHON_SCRIPT}" "${TMPDIR}/agents.lock.toml"
  [ "$status" -eq 0 ]
  # alpha should appear before zulu
  local alpha_line
  alpha_line="$(echo "${output}" | grep -n alpha | head -1)"
  local zulu_line
  zulu_line="$(echo "${output}" | grep -n zulu | head -1)"
  [ "$(echo "${alpha_line}" | cut -d: -f1)" -lt "$(echo "${zulu_line}" | cut -d: -f1)" ]
}

# ── Shell wrapper tests ──────────────────────────────────────────────

@test "shell wrapper works with valid lockfile" {
  cat > "${TMPDIR}/agents.lock.toml" <<'EOF'
schema_version = "1"

[agents.alpha]
repo             = "DarojaAI/alpha"
handle           = "@alpha"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/alpha/blob/main/.openclaw/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
EOF

  run bash "${SHELL_WRAPPER}" "${TMPDIR}/agents.lock.toml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"alpha"* ]]
}

@test "shell wrapper works with missing file" {
  run bash "${SHELL_WRAPPER}" "${TMPDIR}/nonexistent.lock.toml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"No agents.lock.toml found"* ]]
}

@test "shell wrapper uses default path when no argument" {
  # The wrapper defaults to config/agents.lock.toml relative to repo root.
  # If the repo has that file, it should succeed.
  run bash "${SHELL_WRAPPER}"
  [ "$status" -eq 0 ]
}
