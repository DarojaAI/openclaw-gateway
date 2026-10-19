#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# tests/cross-agent-task.bats — C1 CLI contract tests (fleet plan C1/C2,
# issue #164). Wire shape per linux-desktop-seed
# docs/contracts/SQLITE-STATE-BOUNDARY.md sibling CROSS-AGENT-TASK-BUS.md:
#   _pending/ -> _active/ -> _done/, schema v0, atomic state transitions
#   under flock, id ^[a-z0-9][a-z0-9-]*$, ISO-8601 UTC timestamps.
# Hermetic via TASK_BUS_ROOT (the contract's discovery override).
# -----------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export CLI="${REPO_ROOT}/scripts/cross-agent-task.py"
    export TASK_BUS_ROOT="$(mktemp -d)/bus"
    export OPENCLAW_AGENT_ID="test-lane"
}

teardown() { rm -rf "$(dirname "$TASK_BUS_ROOT")"; }

submit() { python3 "$CLI" submit "$@"; }

@test "submit creates a schema-v0 task in _pending and prints the id" {
    id="$(submit --to other-lane --subject 'sync now')"
    [ "$?" -eq 0 ]
    [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]]
    jq -e --arg id "$id" '
        .id == $id and .schema_version == "v0"
        and .from == "test-lane" and .to == "other-lane"
        and .subject == "sync now"
        and (.created_at | test("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$"))
    ' "$TASK_BUS_ROOT/_pending/$id.json" >/dev/null
}

@test "claim moves the task to _active with claimed_by/claimed_at" {
    id="$(submit --to other-lane --subject 'sync now')"
    run python3 "$CLI" claim "$id"
    [ "$status" -eq 0 ]
    [ ! -f "$TASK_BUS_ROOT/_pending/$id.json" ]
    jq -e --arg id "$id" '
        .id == $id and .claimed_by == "test-lane"
        and (.claimed_at | test("Z$"))
    ' "$TASK_BUS_ROOT/_active/$id.json" >/dev/null
}

@test "complete moves the task to _done with completed_at" {
    id="$(submit --to other-lane --subject 'sync now')"
    python3 "$CLI" claim "$id" > /dev/null
    run python3 "$CLI" complete "$id" --result 'done-ok'
    [ "$status" -eq 0 ]
    [ ! -f "$TASK_BUS_ROOT/_active/$id.json" ]
    jq -e --arg id "$id" '.id == $id and .result == "done-ok"' \
        "$TASK_BUS_ROOT/_done/$id.json" > /dev/null
}

@test "claim on a missing task fails with exit 1" {
    run python3 "$CLI" claim no-such-task
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found in _pending"* ]]
}

@test "complete on an unclaimed task fails (wrong state)" {
    id="$(submit --to other-lane --subject 'sync now')"
    run python3 "$CLI" complete "$id"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found in _active"* ]]
}

@test "invalid task id characters are rejected" {
    run python3 "$CLI" claim 'Bad_Id!'
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid task id"* ]]
}

@test "double claim: second claimer loses (atomic rename semantics)" {
    id="$(submit --to other-lane --subject 'sync now')"
    python3 "$CLI" claim "$id" --agent lane-a > /dev/null
    run python3 "$CLI" claim "$id" --agent lane-b
    [ "$status" -eq 1 ]
    # First claimer's ownership is intact.
    jq -e '.claimed_by == "lane-a"' "$TASK_BUS_ROOT/_active/$id.json" > /dev/null
}

@test "list filters by state" {
    a="$(submit --to other-lane --subject 'p1')"
    b="$(submit --to other-lane --subject 'p2')"
    python3 "$CLI" claim "$a" > /dev/null
    run python3 "$CLI" list --state active
    [ "$status" -eq 0 ]
    [[ "$output" == *'"subject": "p1"'* ]]
    [[ "$output" == *'"_state": "active"'* ]]
    [[ "$output" != *'"_state": "pending"'* ]]
}

@test "concurrent claims: exactly one wins" {
    id="$(submit --to other-lane --subject 'race')"
    python3 "$CLI" list --state all > /dev/null
    ( python3 "$CLI" claim "$id" --agent lane-a > /dev/null 2>&1; echo $? > "$TASK_BUS_ROOT/../rc_a" ) &
    ( python3 "$CLI" claim "$id" --agent lane-b > /dev/null 2>&1; echo $? > "$TASK_BUS_ROOT/../rc_b" ) &
    wait
    wins=0
    [ "$(cat "$TASK_BUS_ROOT/../rc_a")" = "0" ] && wins=$((wins+1))
    [ "$(cat "$TASK_BUS_ROOT/../rc_b")" = "0" ] && wins=$((wins+1))
    [ "$wins" -eq 1 ]
}
