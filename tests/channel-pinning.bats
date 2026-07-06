#!/usr/bin/bats
#
# channel-pinning.bats — Tests for channel pinning enforcement (RFC #31 Phase 5).
#
# Covers:
#   - dry-run violation (default) — exit 0, decision emitted with violation=true,
#     one-line CHANNEL_PINNING_VIOLATION record on stderr
#   - dry-run OK channel — exit 0, channel_pinning.violation=false
#   - enforcement OK channel — exit 0, channel_pinning.enforced=true
#   - enforcement violation — exit 4, no stdout routing decision, stderr log
#   - per-agent dry_run=false + enforce_channel_pinning=true → enforcement
#   - per-agent dry_run=true + enforce_channel_pinning=true → still dry-run
#     (enforcement requires dry_run=false)
#   - back-compat: no --channel → no channel_pinning field in output
#   - cap-dispatch parity (same behavior via capability-dispatch.py)
#
# Note on capture: BATS 1.x `run` interleaves stderr into $output (it captures
# fd 2 internally). We capture stdout/stderr to temp files directly (without
# using `run`) so they're independently inspectable.
#

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROUTE_SCRIPT="${REPO_ROOT}/scripts/route-by-handle.py"
DISPATCH_SCRIPT="${REPO_ROOT}/scripts/capability-dispatch.py"
CHANNEL_PINNING_SCRIPT="${REPO_ROOT}/scripts/channel_pinning.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Make a lockfile with given per-agent fields.
# Args: lockfile_path dry_run enforce_channel_pinning allowed_channels_csv
make_lockfile() {
    local path="$1"
    local dry_run="$2"
    local enforce="$3"
    local allowed_csv="$4"
    python3 - "$path" "$dry_run" "$enforce" "$allowed_csv" << 'PYEOF'
import sys
path, dry_run, enforce, allowed_csv = sys.argv[1:]
allowed_list = [x.strip() for x in allowed_csv.split(",") if x.strip()]
allowed_toml = "[" + ", ".join(f'"{c}"' for c in allowed_list) + "]"
with open(path, "w") as fh:
    fh.write(f"""schema_version = "1"

[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@linux-desktop-seed"
contract_version = "v1"
config_source    = "https://example.com/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
capabilities     = ["vm-provision"]
role             = "executor"
allowed_channels = {allowed_toml}
dry_run          = {str(dry_run).lower()}
enforce_channel_pinning = {str(enforce).lower()}
""")
PYEOF
}

# Run route-by-handle.py; capture stdout, stderr, exit code into globals:
#   STATUS, OUTPUT, STDERR_CAPTURED.
route() {
    local lockfile="$1"
    shift
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    # Disable BATS strict mode for this function: exit 4 is a valid
    # outcome we want to capture, not an error to fail on.
    set +e
    python3 "${ROUTE_SCRIPT}" --lockfile "${lockfile}" "$@" \
        > "${stdout_file}" 2> "${stderr_file}"
    STATUS=$?
    set -e
    OUTPUT="$(cat "${stdout_file}")"
    STDERR_CAPTURED="$(cat "${stderr_file}")"
    rm -f "${stdout_file}" "${stderr_file}"
}

dispatch() {
    local lockfile="$1"
    shift
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    set +e
    python3 "${DISPATCH_SCRIPT}" --lockfile "${lockfile}" "$@" \
        > "${stdout_file}" 2> "${stderr_file}"
    STATUS=$?
    set -e
    OUTPUT="$(cat "${stdout_file}")"
    STDERR_CAPTURED="$(cat "${stderr_file}")"
    rm -f "${stdout_file}" "${stderr_file}"
}

setup() {
    TMP_LOCKFILE="$(mktemp)"
    OUTPUT=""
    STDERR_CAPTURED=""
    STATUS=0
}

teardown() {
    if [[ -n "${TMP_LOCKFILE:-}" && -f "${TMP_LOCKFILE}" ]]; then
        rm -f "${TMP_LOCKFILE}"
    fi
}

# ---------------------------------------------------------------------------
# Tests — Default dry-run mode
# ---------------------------------------------------------------------------

@test "default dry-run: OK channel emits routing decision with violation=false" {
    make_lockfile "${TMP_LOCKFILE}" "true" "false" "1501612164098687087"
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 1501612164098687087
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"linux-desktop-seed"* ]]
    [[ "$OUTPUT" == *'"violation": false'* ]]
    [[ "$OUTPUT" == *'"dry_run": true'* ]]
    [[ "$OUTPUT" == *'"enforced": false'* ]]
}

@test "default dry-run: violation logged to stderr, decision still emitted, exit 0" {
    make_lockfile "${TMP_LOCKFILE}" "true" "false" "1501612164098687087"
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 999999999999
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"linux-desktop-seed"* ]]
    [[ "$OUTPUT" == *'"violation": true'* ]]
    [[ "$STDERR_CAPTURED" == *"CHANNEL_PINNING_VIOLATION"* ]]
    [[ "$STDERR_CAPTURED" == *"handle=@linux-desktop-seed"* ]]
    [[ "$STDERR_CAPTURED" == *"channel=999999999999"* ]]
}

@test "default dry-run: omitted dry_run field defaults to True" {
    python3 - "${TMP_LOCKFILE}" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, "w") as fh:
    fh.write("""schema_version = "1"

[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@linux-desktop-seed"
contract_version = "v1"
config_source    = "https://example.com/agent-config.yaml"
config_sha       = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
capabilities     = ["vm-provision"]
role             = "executor"
allowed_channels = ["1501612164098687087"]
""")
PYEOF
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 999999999999
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"linux-desktop-seed"* ]]
    [[ "$OUTPUT" == *'"violation": true'* ]]
    [[ "$OUTPUT" == *'"dry_run": true'* ]]
}

# ---------------------------------------------------------------------------
# Tests — Enforcement mode
# ---------------------------------------------------------------------------

@test "enforcement: OK channel emits decision with enforced=true" {
    make_lockfile "${TMP_LOCKFILE}" "false" "true" "1501612164098687087"
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 1501612164098687087
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"linux-desktop-seed"* ]]
    [[ "$OUTPUT" == *'"violation": false'* ]]
    [[ "$OUTPUT" == *'"dry_run": false'* ]]
    [[ "$OUTPUT" == *'"enforced": true'* ]]
}

@test "enforcement: violation exits 4, no stdout decision, stderr log" {
    make_lockfile "${TMP_LOCKFILE}" "false" "true" "1501612164098687087"
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 999999999999
    [ "$STATUS" -eq 4 ]
    [[ "$OUTPUT" != *"config_source"* ]]
    [[ "$STDERR_CAPTURED" == *"CHANNEL_PINNING_VIOLATION"* ]]
    [[ "$STDERR_CAPTURED" == *"dry_run=False"* ]]
}

@test "enforcement requires both flags: enforce=true + dry_run=true is still dry-run" {
    make_lockfile "${TMP_LOCKFILE}" "true" "true" "1501612164098687087"
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 999999999999
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *'"violation": true'* ]]
    [[ "$OUTPUT" == *'"dry_run": true'* ]]
    [[ "$OUTPUT" == *'"enforced": false'* ]]
}

@test "enforcement: enforce_channel_pinning=false (default) → dry-run even when dry_run=false" {
    make_lockfile "${TMP_LOCKFILE}" "false" "false" "1501612164098687087"
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 999999999999
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *'"violation": true'* ]]
    [[ "$OUTPUT" == *'"enforced": false'* ]]
}

# ---------------------------------------------------------------------------
# Tests — Multi-channel allowed_channels
# ---------------------------------------------------------------------------

@test "multi-channel: second allowed channel still passes" {
    make_lockfile "${TMP_LOCKFILE}" "true" "false" "111111111111111111,222222222222222222"
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 222222222222222222
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"linux-desktop-seed"* ]]
    [[ "$OUTPUT" == *'"violation": false'* ]]
}

@test "multi-channel: disallowed third channel is logged" {
    make_lockfile "${TMP_LOCKFILE}" "true" "false" "111111111111111111,222222222222222222"
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 333333333333333333
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *'"violation": true'* ]]
    [[ "$STDERR_CAPTURED" == *"channel=333333333333333333"* ]]
}

# ---------------------------------------------------------------------------
# Tests — Back-compat (no --channel)
# ---------------------------------------------------------------------------

@test "back-compat: no --channel means no channel_pinning field in output" {
    make_lockfile "${TMP_LOCKFILE}" "true" "false" "1501612164098687087"
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"linux-desktop-seed"* ]]
    [[ "$OUTPUT" != *"channel_pinning"* ]]
    [[ "$STDERR_CAPTURED" != *"CHANNEL_PINNING_VIOLATION"* ]]
}

@test "back-compat: empty --channel means no channel_pinning field in output" {
    make_lockfile "${TMP_LOCKFILE}" "true" "false" "1501612164098687087"
    route "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel ""
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"linux-desktop-seed"* ]]
    [[ "$OUTPUT" != *"channel_pinning"* ]]
}

# ---------------------------------------------------------------------------
# Tests — capability-dispatch.py parity
# ---------------------------------------------------------------------------

@test "capability-dispatch: dry-run violation logged, decision emitted" {
    make_lockfile "${TMP_LOCKFILE}" "true" "false" "1501612164098687087"
    dispatch "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 999999999999
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"linux-desktop-seed"* ]]
    [[ "$OUTPUT" == *'"violation": true'* ]]
    [[ "$STDERR_CAPTURED" == *"CHANNEL_PINNING_VIOLATION"* ]]
}

@test "capability-dispatch: enforcement violation exits 4" {
    make_lockfile "${TMP_LOCKFILE}" "false" "true" "1501612164098687087"
    dispatch "${TMP_LOCKFILE}" --handle @linux-desktop-seed --channel 999999999999
    [ "$STATUS" -eq 4 ]
    [[ "$OUTPUT" != *"config_source"* ]]
    [[ "$STDERR_CAPTURED" == *"CHANNEL_PINNING_VIOLATION"* ]]
}

@test "capability-dispatch: capability routing also checks channel pinning" {
    make_lockfile "${TMP_LOCKFILE}" "false" "true" "1501612164098687087"
    dispatch "${TMP_LOCKFILE}" --capability vm-provision --channel 999999999999
    [ "$STATUS" -eq 4 ]
    [[ "$STDERR_CAPTURED" == *"CHANNEL_PINNING_VIOLATION"* ]]
    [[ "$STDERR_CAPTURED" == *"handle=@linux-desktop-seed"* ]]
}

# ---------------------------------------------------------------------------
# Tests — channel_pinning module unit-ish (call directly via Python)
# ---------------------------------------------------------------------------

@test "module: check_channel_pinning returns allowed=True on no channel context" {
    OUTPUT="$(python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/scripts')
from channel_pinning import check_channel_pinning
agent = {'allowed_channels': ['1501612164098687087']}
result = check_channel_pinning(agent, None)
assert result['allowed'] is True
assert result['violation'] is False
assert result['reason'] == 'no channel context provided'
print('OK')
")"
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"OK"* ]]
}

@test "module: is_dry_run defaults to True when field missing" {
    OUTPUT="$(python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/scripts')
from channel_pinning import is_dry_run, is_enforcement_enabled
agent = {'allowed_channels': ['123']}
assert is_dry_run(agent) is True
assert is_enforcement_enabled(agent) is False
print('OK')
")"
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"OK"* ]]
}

@test "module: enforcement requires both flags (enforce=true AND dry_run=false)" {
    OUTPUT="$(python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/scripts')
from channel_pinning import is_enforcement_enabled
assert is_enforcement_enabled({'enforce_channel_pinning': True, 'dry_run': True}) is False
assert is_enforcement_enabled({'enforce_channel_pinning': False, 'dry_run': False}) is False
assert is_enforcement_enabled({'enforce_channel_pinning': True, 'dry_run': False}) is True
print('OK')
")"
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"OK"* ]]
}

@test "module: get_allowed_channels normalizes int items to strings" {
    OUTPUT="$(python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/scripts')
from channel_pinning import get_allowed_channels
agent = {'allowed_channels': [123456789012345678, '999']}
got = get_allowed_channels(agent)
assert got == ['123456789012345678', '999']
assert get_allowed_channels({}) == []
print('OK')
")"
    [ "$STATUS" -eq 0 ]
    [[ "$OUTPUT" == *"OK"* ]]
}
