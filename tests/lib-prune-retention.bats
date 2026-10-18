#!/usr/bin/env bats
#
# tests/lib-prune-retention.bats
#
# Tests for scripts/lib-prune-retention.py capture-tree protection
# (DarojaAI/openclaw-gateway#141).
#
# The incident: the retention pruner deleted companion files (README.md,
# LICENSE.md) out of plugin-captures trees still referenced by installed
# npm plugin projects, so the next plugin admission failed hash comparison
# ("Native plugin companion changed during admission") and Discord stayed
# down while /healthz returned 200.
#
# Contract under test:
#   1. A capture tree carrying a live lease (owner.sqlite or its
#      -journal/-wal/-shm sidecars) is referenced -> NEVER pruned, skipped
#      with a warning, even when every file is older than the age cap and
#      total size exceeds the byte cap.
#   2. A token-less tree stays referenced while the installed-plugin
#      registry is non-empty -> skipped + warned, never pruned.
#   3. A token-less tree with a registry proving ZERO installed plugins
#      may be pruned, but only as a whole tree (never file-by-file); trees
#      with live leases in the same run stay protected.
#   4. Registry unreadable/missing -> fail-loud: every capture tree is
#      skipped with a warning; nothing is deleted.
#   5. Non-capture files at the target root still follow the old generic
#      policy.
#   6. Generic mode (no capture markers) is byte-compatible with the old
#      per-file behavior.
#   7. --no-capture-aware is the explicit escape hatch back to generic
#      behavior.
#   8. A symlinked lease token is ambiguous -> protected.
#   9. Dry-run never deletes.
#
# Runs in <3s; no real systemd, no openclaw runtime.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/lib-prune-retention.py"
    BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
    WORK="$BATS_TEST_TMPDIR/openclaw"
    CAP="$WORK/tmp/plugin-captures"
    mkdir -p "$CAP"
    # Fixed "old" timestamp: far past every retention horizon used here.
    OLD_EPOCH=$(( $(date +%s) - 40 * 86400 ))
}

teardown() {
    if [ -n "$BATS_TEST_TMPDIR" ] && [ -d "$BATS_TEST_TMPDIR/openclaw" ]; then
        rm -rf "$BATS_TEST_TMPDIR/openclaw"
    fi
}

# --- fixtures ---------------------------------------------------------------

# make_capture_tree <root> <tree-name> <file:size,file:size,...>
# Creates <root>/<tree-name>/captures/<file> with old mtimes. Optionally
# adds a lease token when <tree-name> ends with "-lease".
make_capture_tree() {
    local root="$1" name="$2" spec="$3" file size
    mkdir -p "$root/$name/captures"
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        file="${entry%%:*}"
        size="${entry##*:}"
        printf '%*s' "$size" '' > "$root/$name/captures/$file"
        touch -d "@$OLD_EPOCH" "$root/$name/captures/$file"
    done
    if [[ "$name" == *-lease ]]; then
        : > "$root/$name/owner.sqlite"
    fi
}

# make_registry <state-dir> <install-records-json>
# Creates <state-dir>/state/openclaw-state.sqlite with one
# installed_plugin_index row carrying the given install_records_json.
make_registry() {
    local state_dir="$1" records="$2"
    python3 - "$state_dir" "$records" <<'PY'
import json
import os
import sqlite3
import sys

state_dir, records = sys.argv[1], sys.argv[2]
db_dir = os.path.join(state_dir, "state")
os.makedirs(db_dir, exist_ok=True)
con = sqlite3.connect(os.path.join(db_dir, "openclaw-state.sqlite"))
con.execute(
    "CREATE TABLE installed_plugin_index ("
    " index_key TEXT NOT NULL PRIMARY KEY, version INTEGER NOT NULL,"
    " host_contract_version TEXT NOT NULL, compat_registry_version TEXT NOT NULL,"
    " migration_version INTEGER NOT NULL, policy_hash TEXT NOT NULL,"
    " generated_at_ms INTEGER NOT NULL, refresh_reason TEXT,"
    " install_records_json TEXT NOT NULL, plugins_json TEXT NOT NULL,"
    " diagnostics_json TEXT NOT NULL, warning TEXT, updated_at_ms INTEGER NOT NULL"
    ") STRICT"
)
con.execute(
    "INSERT INTO installed_plugin_index VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (
        "k", 1, "h", "c", 1, "p", 1, None, records, "{}", "{}", None, 1,
    ),
)
con.commit()
con.close()
PY
}

# --- tests ------------------------------------------------------------------

@test "live-lease capture tree is never pruned; companions survive age+size caps" {
    make_capture_tree "$CAP" "referenced-lease" "index.js:100,README.md:40,LICENSE.md:50"
    # Every file is 40 days old and total (190 B) exceeds a 100 B cap.
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 100 \
        --state-dir "$WORK" --delete
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "skipped (referenced capture): .*/referenced-lease (live lease (owner.sqlite))"
    echo "$output" | grep -q "skipped 1 capture tree(s) (referenced,"
    [ -f "$CAP/referenced-lease/captures/README.md" ]
    [ -f "$CAP/referenced-lease/captures/LICENSE.md" ]
    [ -f "$CAP/referenced-lease/captures/index.js" ]
    [ -f "$CAP/referenced-lease/owner.sqlite" ]
}

@test "lease sidecar alone (owner.sqlite-wal) protects the whole tree" {
    local tree="$CAP/sidecar-lease"
    mkdir -p "$tree/captures"
    printf 'companion' > "$tree/captures/README.md"
    touch -d "@$OLD_EPOCH" "$tree/captures/README.md"
    : > "$tree/owner.sqlite-wal"
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 1 --state-dir "$WORK" --delete
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "live lease (owner.sqlite-wal)"
    [ -f "$tree/captures/README.md" ]
}

@test "token-less capture tree is protected while installed plugins exist" {
    make_capture_tree "$CAP" "orphan-tree" "index.js:50,README.md:30"
    make_registry "$WORK" '{"discord": {"installPath": "/home/u/.openclaw/plugins/packages/discord"}}'
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 50 --state-dir "$WORK" --delete
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "skipped (referenced capture): .*/orphan-tree (installed plugins present (registry non-empty))"
    [ -f "$CAP/orphan-tree/captures/index.js" ]
    [ -f "$CAP/orphan-tree/captures/README.md" ]
}

@test "token-less tree with provably-empty registry is pruned whole; lease tree kept" {
    make_capture_tree "$CAP" "stale-tree" "index.js:60"
    make_capture_tree "$CAP" "kept-lease" "index.js:30,README.md:20"
    make_registry "$WORK" '{}'
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 0 --state-dir "$WORK" --delete
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^deleted: $CAP/stale-tree$"
    echo "$output" | grep -q "skipped (referenced capture): .*/kept-lease (live lease (owner.sqlite))"
    [ ! -e "$CAP/stale-tree" ]
    [ -f "$CAP/kept-lease/captures/README.md" ]
}

@test "unreadable registry fails loud: nothing deleted, skip reason reported" {
    make_capture_tree "$CAP" "no-state-tree" "index.js:40"
    # No state dir, no installs.json anywhere: registry unknowable.
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 10 --state-dir "$WORK" --delete
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "skipped (referenced capture): .*/no-state-tree (installed-plugin registry unavailable)"
    echo "$output" | grep -q "summary: nothing to prune; skipped 1 capture tree(s)"
    [ -f "$CAP/no-state-tree/captures/index.js" ]
}

@test "stray non-capture files are still pruned while capture trees are protected" {
    make_capture_tree "$CAP" "kept-lease" "index.js:20"
    printf 'garbage' > "$CAP/stray.tmp"
    touch -d "@$OLD_EPOCH" "$CAP/stray.tmp"
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 0 --state-dir "$WORK" --delete
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^deleted: $CAP/stray.tmp$"
    [ ! -e "$CAP/stray.tmp" ]
    [ -f "$CAP/kept-lease/captures/index.js" ]
}

@test "generic mode (no capture markers) keeps per-file behavior" {
    local plain="$WORK/tmp/plain"
    mkdir -p "$plain/sub"
    printf 'old-one' > "$plain/old1.txt"
    printf 'old-two' > "$plain/sub/old2.txt"
    touch -d "@$OLD_EPOCH" "$plain/old1.txt" "$plain/sub/old2.txt"
    run python3 "$SCRIPT" --dir "$plain" --max-age-days 2 --max-bytes 0 --state-dir "$WORK"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "capture_aware=no"
    echo "$output" | grep -q "^would delete: $plain/old1.txt$"
    echo "$output" | grep -q "^would delete: $plain/sub/old2.txt$"
    if echo "$output" | grep -q "skipped (referenced capture)"; then
        return 1
    fi
    [ -f "$plain/old1.txt" ] # dry-run deletes nothing
}

@test "--no-capture-aware restores generic per-file behavior (escape hatch)" {
    make_capture_tree "$CAP" "forced-generic-lease" "index.js:20,README.md:10"
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 0 \
        --state-dir "$WORK" --delete --no-capture-aware
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "capture_aware=no"
    if echo "$output" | grep -q "skipped (referenced capture)"; then
        return 1
    fi
    [ ! -f "$CAP/forced-generic-lease/captures/index.js" ]
    [ ! -f "$CAP/forced-generic-lease/captures/README.md" ]
}

@test "symlinked lease token is ambiguous -> protected" {
    local tree="$CAP/symlink-lease"
    make_capture_tree "$CAP" "symlink-lease" "LICENSE.md:30"
    rm -f "$tree/owner.sqlite"
    printf 'token-bytes' > "$WORK/token-target"
    ln -s "$WORK/token-target" "$tree/owner.sqlite"
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 1 --state-dir "$WORK" --delete
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "skipped (referenced capture): .*/symlink-lease (ambiguous lease token"
    [ -f "$tree/captures/LICENSE.md" ]
}

@test "dry-run reports but never deletes, even for provably-unreferenced trees" {
    make_capture_tree "$CAP" "dryrun-tree" "index.js:60"
    make_registry "$WORK" '{}'
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 0 --state-dir "$WORK"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^would delete: $CAP/dryrun-tree$"
    [ -d "$CAP/dryrun-tree" ]
    [ -f "$CAP/dryrun-tree/captures/index.js" ]
}

@test "legacy capture name is protected while plugins are installed" {
    # openclaw-plugin-build-* is a legacy capture instance name; with
    # installed plugins present it must be treated as referenced.
    make_capture_tree "$CAP" "openclaw-plugin-build-abc123" "index.js:40"
    make_registry "$WORK" '{"discord": {"installPath": "/x/discord"}}'
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 0 --state-dir "$WORK" --delete
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "skipped (referenced capture): .*/openclaw-plugin-build-abc123 (installed plugins present (registry non-empty))"
    [ -f "$CAP/openclaw-plugin-build-abc123/captures/index.js" ]
}

@test "legacy capture name with empty registry follows the same whole-tree rule" {
    make_capture_tree "$CAP" "openclaw-plugin-build-xyz789" "index.js:40"
    make_registry "$WORK" '{}'
    run python3 "$SCRIPT" --dir "$CAP" --max-age-days 2 --max-bytes 0 --state-dir "$WORK" --delete
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^deleted: $CAP/openclaw-plugin-build-xyz789$"
    [ ! -e "$CAP/openclaw-plugin-build-xyz789" ]
}