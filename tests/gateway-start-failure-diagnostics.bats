#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# tests/gateway-start-failure-diagnostics.bats — issue #165 consumer
# mitigation. Hermetic: fake openclaw/journalctl/df on PATH; fake systemd
# state via the collector's own surfaces. Verdicts per
# docs/contracts/SQLITE-STATE-BOUNDARY.md (corruption signature,
# unclean-close signature, disk pressure, no signature).
# -----------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export SCRIPT="${REPO_ROOT}/scripts/diagnose-gateway-start-failure.py"
    export TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin" "$TMP/home/desktopuser/.openclaw/state"
    export HOME="$TMP/home"
    export PATH="$TMP/bin:$PATH"

    # Default fakes: healthy gateway, clean doctor, sane disk.
    printf '#!/usr/bin/env bash\necho "integrity: ok"\n' > "$TMP/bin/openclaw"
    chmod +x "$TMP/bin/openclaw"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/journalctl"
    chmod +x "$TMP/bin/journalctl"
    printf '#!/usr/bin/env bash\necho "/dev/sda1 150G 90G 60G 60%% /"\n' > "$TMP/bin/df"
    chmod +x "$TMP/bin/df"
}

teardown() { rm -rf "$TMP"; }

@test "collector runs to completion on clean state" {
    python3 -c "import ast; ast.parse(open('$SCRIPT').read())"
    run python3 "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# gateway start-failure diagnostics"* ]]
    [[ "$output" == *"VERDICT:"* ]]
}

@test "corruption marker in doctor --lint -> corruption verdict with refusal path" {
    printf '#!/usr/bin/env bash\nexec /usr/bin/sqlite3 "$@"\n' > /dev/null  # no-op guard
    cat > "$TMP/bin/openclaw" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "doctor" ]; then
  echo "state database unreadable: database disk image is malformed"
  exit 1
fi
echo "ok"
FAKE
    chmod +x "$TMP/bin/openclaw"
    run python3 "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERDICT: corruption signature"* ]]
    [[ "$output" == *"PRESERVE the database and its WAL"* ]]
}

@test "sidecars present + gateway stopped -> unclean-close verdict" {
    printf '#!/usr/bin/env bash\nexit 3\n' > "$TMP/bin/systemctl"  # not active
    chmod +x "$TMP/bin/systemctl"
    mkdir -p "$HOME/.openclaw/state"
    printf 'stale' > "$HOME/.openclaw/state/openclaw.sqlite-wal"
    run python3 "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNCLEAN-CLOSE SIGNATURE"* ]]
}

@test "disk pressure -> disk-pressure verdict" {
    printf '#!/usr/bin/env bash\necho "/dev/sda1 150G 149G 1G 99%% /"\n' > "$TMP/bin/df"
    chmod +x "$TMP/bin/df"
    run python3 "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERDICT: disk-pressure signature"* ]]
}

@test "clean state -> no known failure signature" {
    run python3 "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERDICT: no known failure signature"* ]]
}
