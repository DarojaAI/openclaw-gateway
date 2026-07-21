#!/usr/bin/env bats
#
# tests/generate-bindings-from-lockfile.bats
#
# Tests for scripts/generate-bindings-from-lockfile.py
#

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/.."
  SCRIPT="${REPO_ROOT}/scripts/generate-bindings-from-lockfile.py"
  TMPDIR="${BATS_TMPDIR}/gen-bindings-$$"
  mkdir -p "${TMPDIR}/config"
}

teardown() {
  rm -rf "${TMPDIR}"
}

# ── Helpers ──────────────────────────────────────────────────────────

make_lockfile() {
  local path="${1:-${TMPDIR}/config/agents.lock.toml}"
  cat > "${path}" <<'EOF'
schema_version = "1"

[agents.darojaai_architect]
handle           = "@darojaai-architect"
allowed_channels = ["1501612164098687087"]
role             = "advisor"
capabilities     = ["architecture", "code-review"]

[agents.linux-desktop-seed]
handle           = "@linux-desktop-seed"
allowed_channels = ["1501612164098687087", "999999999999999999"]
role             = "executor"
capabilities     = ["vm-provision"]

[agents.no-channels-agent]
handle           = "@no-channels"
role             = "executor"
capabilities     = ["testing"]
EOF
}

make_lockfile_single() {
  local path="${1:-${TMPDIR}/config/agents.lock.toml}"
  cat > "${path}" <<'EOF'
schema_version = "1"

[agents.darojaai_architect]
handle           = "@darojaai-architect"
allowed_channels = ["1501612164098687087"]
role             = "advisor"
capabilities     = ["architecture", "code-review"]
EOF
}

make_lockfile_two_channels() {
  local path="${1:-${TMPDIR}/config/agents.lock.toml}"
  cat > "${path}" <<'EOF'
schema_version = "1"

[agents.multi-agent]
handle           = "@multi-agent"
allowed_channels = ["111111111111111111", "222222222222222222"]
role             = "executor"
capabilities     = ["general"]
EOF
}

make_openclaw_json() {
  local path="${1:-${TMPDIR}/config/openclaw.json}"
  python3 -c "
import json, sys
data = {'bindings': [{'agentId': 'hand-written-agent', 'match': {'channel': 'discord', 'peer': {'id': '1234567890'}}}]}
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "${path}"
}

make_openclaw_json_empty() {
  local path="${1:-${TMPDIR}/config/openclaw.json}"
  echo '{}' > "${path}"
}

# ── Tests ────────────────────────────────────────────────────────────

@test "generates correct bindings from sample lockfile" {
  make_lockfile
  make_openclaw_json_empty
  run python3 "${SCRIPT}" --lockfile "${TMPDIR}/config/agents.lock.toml" --openclaw-json "${TMPDIR}/config/openclaw.json" --output "${TMPDIR}/output.json"
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
bindings = data.get('bindings', [])
ids = [b['agentId'] for b in bindings]
# darojaai_architect: 1 channel, linux-desktop-seed: 2 channels = 3 total
assert len(bindings) == 3, f'expected 3 bindings, got {len(bindings)}: {ids}'
assert 'darojaai_architect' in ids
assert 'linux-desktop-seed' in ids
# no-channels-agent should NOT appear
assert 'no-channels-agent' not in ids, 'no-channels-agent should be excluded'
print('PASS')
" "${TMPDIR}/output.json"
}

@test "multiple channels produce multiple bindings" {
  make_lockfile_two_channels
  make_openclaw_json_empty
  run python3 "${SCRIPT}" --lockfile "${TMPDIR}/config/agents.lock.toml" --openclaw-json "${TMPDIR}/config/openclaw.json" --output "${TMPDIR}/output.json"
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
bindings = data.get('bindings', [])
peer_ids = [b['match']['peer']['id'] for b in bindings]
assert len(bindings) == 2, f'expected 2 bindings, got {len(bindings)}'
assert '111111111111111111' in peer_ids
assert '222222222222222222' in peer_ids
print('PASS')
" "${TMPDIR}/output.json"
}

@test "existing non-lockfile bindings are preserved" {
  make_lockfile_single
  make_openclaw_json
  run python3 "${SCRIPT}" --lockfile "${TMPDIR}/config/agents.lock.toml" --openclaw-json "${TMPDIR}/config/openclaw.json" --output "${TMPDIR}/output.json"
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
bindings = data.get('bindings', [])
ids = [b['agentId'] for b in bindings]
assert 'hand-written-agent' in ids, 'hand-written-agent should be preserved'
assert 'darojaai_architect' in ids, 'lockfile agent should be added'
assert len(bindings) == 2, f'expected 2 bindings, got {len(bindings)}: {ids}'
print('PASS')
" "${TMPDIR}/output.json"
}

@test "existing lockfile bindings are replaced" {
  # Start with an existing binding for darojaai_architect pointing to wrong channel
  echo '{"bindings": [{"agentId": "darojaai_architect", "match": {"channel": "discord", "peer": {"id": "0000000000"}}}]}' > "${TMPDIR}/config/openclaw.json"
  make_lockfile_single
  run python3 "${SCRIPT}" --lockfile "${TMPDIR}/config/agents.lock.toml" --openclaw-json "${TMPDIR}/config/openclaw.json" --output "${TMPDIR}/output.json"
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
bindings = data.get('bindings', [])
arch = [b for b in bindings if b['agentId'] == 'darojaai_architect']
assert len(arch) == 1, f'expected exactly 1 darojaai_architect binding, got {len(arch)}'
assert arch[0]['match']['peer']['id'] == '1501612164098687087', f'wrong channel: {arch[0]}'
print('PASS')
" "${TMPDIR}/output.json"
}

@test "missing lockfile: no changes, exit 0" {
  make_openclaw_json_empty
  run python3 "${SCRIPT}" --lockfile "${TMPDIR}/nonexistent.lock.toml" --openclaw-json "${TMPDIR}/config/openclaw.json" --output "${TMPDIR}/output.json"
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert 'bindings' in data, f'expected bindings key, got {data}'
assert len(data['bindings']) == 0, f'expected 0 bindings, got {len(data[\"bindings\"])}'
print('PASS')
" "${TMPDIR}/output.json"
}

@test "invalid TOML: clear error, non-zero exit" {
  echo 'this is not valid toml {{{' > "${TMPDIR}/config/bad.lock.toml"
  make_openclaw_json_empty
  run python3 "${SCRIPT}" --lockfile "${TMPDIR}/config/bad.lock.toml" --openclaw-json "${TMPDIR}/config/openclaw.json" --output "${TMPDIR}/output.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"error"* ]] || [[ "$output" == *"TOML"* ]]
}

@test "invalid openclaw.json: error, non-zero exit" {
  make_lockfile_single
  echo 'not json at all' > "${TMPDIR}/config/openclaw.json"
  run python3 "${SCRIPT}" --lockfile "${TMPDIR}/config/agents.lock.toml" --openclaw-json "${TMPDIR}/config/openclaw.json" --output "${TMPDIR}/output.json"
  [ "$status" -ne 0 ]
}

@test "--dry-run prints to stdout without writing" {
  make_lockfile
  make_openclaw_json_empty
  run python3 "${SCRIPT}" --lockfile "${TMPDIR}/config/agents.lock.toml" --openclaw-json "${TMPDIR}/config/openclaw.json" --dry-run
  [ "$status" -eq 0 ]
  # Output should be valid JSON with bindings
  echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
bindings = data.get('bindings', [])
assert len(bindings) == 3, f'expected 3 bindings, got {len(bindings)}'
print('PASS')
"
  # The output file should NOT have been created
  [ ! -f "${TMPDIR}/output.json" ]
}

@test "--verbose emits binding details to stderr" {
  make_lockfile_single
  make_openclaw_json_empty
  # Capture stderr separately
  python3 "${SCRIPT}" --lockfile "${TMPDIR}/config/agents.lock.toml" --openclaw-json "${TMPDIR}/config/openclaw.json" --output "${TMPDIR}/output.json" --verbose 2>"${TMPDIR}/stderr.txt"
  [ "$?" -eq 0 ]
  grep -q "binding: agentId=darojaai_architect" "${TMPDIR}/stderr.txt"
  grep -q "total bindings generated: 1" "${TMPDIR}/stderr.txt"
}

@test "binding structure matches expected format" {
  make_lockfile_single
  make_openclaw_json_empty
  run python3 "${SCRIPT}" --lockfile "${TMPDIR}/config/agents.lock.toml" --openclaw-json "${TMPDIR}/config/openclaw.json" --output "${TMPDIR}/output.json"
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
b = data['bindings'][0]
assert b == {
    'agentId': 'darojaai_architect',
    'match': {
        'channel': 'discord',
        'peer': {'id': '1501612164098687087'}
    }
}, f'unexpected binding structure: {b}'
print('PASS')
" "${TMPDIR}/output.json"
}
