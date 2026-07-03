#!/usr/bin/env bats
#
# tests/load-agents-lock.bats
#
# Tests for scripts/load-agents-lock.py and the shell wrapper.
#

setup() {
  export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
  export PYTHON_SCRIPT="${REPO_ROOT}/scripts/load-agents-lock.py"
  export SHELL_WRAPPER="${REPO_ROOT}/scripts/install/openclaw/load-agents-lock.sh"
  TMPDIR="${BATS_TMPDIR}/load-agents-lock-$$"
  mkdir -p "${TMPDIR}"
}

# ── Python script tests ──────────────────────────────────────────────

@test "lockfile with 2 agents loads correctly" {
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

  # Verify JSON output
  local output
  output="$(python3 "${PYTHON_SCRIPT}" "${TMPDIR}/agents.lock.toml")"
  echo "${output}" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['schema_version'] == '1', 'schema_version mismatch'
assert 'alpha' in d.get('agents', {}), 'alpha not in agents'
assert 'beta' in d.get('agents', {}), 'beta not in agents'
assert d['agents']['alpha']['repo'] == 'DarojaAI/alpha'
assert d['agents']['beta']['handle'] == '@beta'
print('PASS')
"
}

@test "missing lockfile returns empty JSON" {
  run python3 "${PYTHON_SCRIPT}" "${TMPDIR}/nonexistent.lock.toml"
  [ "$status" -eq 0 ]

  local output
  output="$(python3 "${PYTHON_SCRIPT}" "${TMPDIR}/nonexistent.lock.toml")"
  # Should be valid JSON with an empty object
  echo "${output}" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert isinstance(d, dict), 'expected dict'
print('PASS')
"
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

@test "lockfile with 3 agents loads correctly" {
  cat > "${TMPDIR}/three.lock.toml" <<'EOF'
schema_version = "1"

[agents.one]
repo             = "DarojaAI/one"
handle           = "@one"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/one/blob/main/.openclaw/agent-config.yaml"
config_sha       = "1111111111111111111111111111111111111111"

[agents.two]
repo             = "DarojaAI/two"
handle           = "@two"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/two/blob/main/.openclaw/agent-config.yaml"
config_sha       = "2222222222222222222222222222222222222222"

[agents.three]
repo             = "DarojaAI/three"
handle           = "@three"
contract_version = "v1"
config_source    = "https://github.com/DarojaAI/three/blob/main/.openclaw/agent-config.yaml"
config_sha       = "3333333333333333333333333333333333333333"
EOF

  run python3 "${PYTHON_SCRIPT}" "${TMPDIR}/three.lock.toml"
  [ "$status" -eq 0 ]

  local output
  output="$(python3 "${PYTHON_SCRIPT}" "${TMPDIR}/three.lock.toml")"
  echo "${output}" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
agents = d.get('agents', {})
assert len(agents) == 3, f'expected 3 agents, got {len(agents)}'
print('PASS')
"
}

# ── Shell wrapper tests ──────────────────────────────────────────────

@test "shell wrapper logs agent count with missing file" {
  run bash "${SHELL_WRAPPER}" "${TMPDIR}/nonexistent.lock.toml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"Loaded 0 agents from agents.lock.toml"* ]]
}

@test "shell wrapper logs agent count with valid lockfile" {
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

  run bash "${SHELL_WRAPPER}" "${TMPDIR}/agents.lock.toml"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"Loaded 2 agents from agents.lock.toml"* ]]
}
