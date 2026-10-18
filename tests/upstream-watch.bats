#!/usr/bin/env bats
#
# tests/upstream-watch.bats
#
# BATS tests for the pure decision logic in scripts/ci/upstream-watch.sh:
# ci_summary verdict derivation, PR/issue/release signature normalization,
# sig_diff field comparison, and the #176080 unblock (blocker-label removal)
# predicate. All hermetic: fixtures are inline JSON, no gh, no network.

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/ci/upstream-watch.sh"

setup() {
	# shellcheck source=/dev/null
	source "$SCRIPT"
}

# --- ci_summary: CI verdict derivation ------------------------------------

@test "ci_summary: all success -> success" {
	run ci_summary '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"neutral"}]}'
	[ "$status" -eq 0 ]
	[ "$output" = "success" ]
}

@test "ci_summary: any failure -> failure (even with successes)" {
	run ci_summary '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}'
	[ "$output" = "failure" ]
}

@test "ci_summary: an in-progress run -> pending" {
	run ci_summary '{"check_runs":[{"status":"in_progress","conclusion":null},{"status":"completed","conclusion":"success"}]}'
	[ "$output" = "pending" ]
}

@test "ci_summary: empty list -> unknown" {
	run ci_summary '{"check_runs":[]}'
	[ "$output" = "unknown" ]
}

@test "ci_summary: bare array form also works" {
	run ci_summary '[{"status":"completed","conclusion":"success"}]'
	[ "$output" = "success" ]
}

# --- normalize_pr / normalize_pr_ci ----------------------------------------

# fixture <content> -- persist a fixture string to a temp file path, echo the
# absolute path (normalize_* read a FILE, not argv, to dodge ARG_MAX).
fixture() {
	local content="$1" f
	f="$(mktemp "${BATS_TEST_TMPDIR:-/tmp}/uw-fixture.XXXXXX.json")"
	printf '%s\n' "$content" > "$f"
	printf '%s\n' "$f"
}

@test "normalize_pr_ci: merges CI verdict + approval into signature" {
	payload='{"pull":{"state":"open","merged":false,"title":"t","html_url":"u","head":{"sha":"abc"}},"reviews":[{"state":"APPROVED"}],"checks":{"check_runs":[{"status":"completed","conclusion":"success"}]}}'
	run normalize_pr_ci "$(fixture "$payload")"
	[ "$status" -eq 0 ]
	run jq -e '.ci == "success" and .approved == true and .state == "open" and .merged == false' <<< "$output"
	[ "$status" -eq 0 ]
}

@test "normalize_pr_ci: no approvals -> approved false" {
	payload='{"pull":{"state":"open","merged":false,"head":{"sha":"abc"}},"reviews":[],"checks":{"check_runs":[]}}'
	run normalize_pr_ci "$(fixture "$payload")"
	run jq -e '.approved == false and .approved_count == 0' <<< "$output"
	[ "$status" -eq 0 ]
}

# --- normalize_issue --------------------------------------------------------

@test "normalize_issue: counts cross-referenced PRs + clawsweeper label" {
	payload='{"issue":{"state":"open","title":"t","html_url":"u","labels":[{"name":"clawsweeper:no-new-fix-pr"}]},"comments":[{"id":7,"user":{"login":"clawsweeper[bot]"}}],"timeline":[{"event":"cross-referenced","source":{"issue":{"pull_request":{},"repository":{"full_name":"openclaw/openclaw"}}}}]}'
	run normalize_issue "$(fixture "$payload")"
	[ "$status" -eq 0 ]
	run jq -e '.clawsweeper_label == true and .linked_prs == 1 and .latest_comment_author == "clawsweeper[bot]"' <<< "$output"
	[ "$status" -eq 0 ]
}

@test "normalize_issue: non-PR / foreign-repo cross-refs are not linked PRs" {
	payload='{"issue":{"state":"closed","title":"t","html_url":"u","labels":[]},"comments":[],"timeline":[{"event":"cross-referenced","source":{"issue":{"pull_request":{},"repository":{"full_name":"DarojaAI/linux-desktop-seed"}}}},{"event":"cross-referenced","source":{"issue":{"pull_request":null,"repository":{"full_name":"openclaw/openclaw"}}}}]}'
	run normalize_issue "$(fixture "$payload")"
	run jq -e '.linked_prs == 0 and .state == "closed"' <<< "$output"
	[ "$status" -eq 0 ]
}

# --- normalize_release ------------------------------------------------------

@test "normalize_release: anchor_ahead when compare is ahead" {
	run normalize_release "$(fixture '{"release":{"tag_name":"v2026.10.4","name":"n","published_at":"2026-10-16T00:00:00Z","html_url":"u"},"compare":{"status":"ahead"}}')"
	[ "$status" -eq 0 ]
	run jq -e '.latest_tag == "v2026.10.4" and .anchor_ahead == true' <<< "$output"
	[ "$status" -eq 0 ]
}

@test "normalize_release: anchor_ahead false when compare null/unknown" {
	run normalize_release "$(fixture '{"release":{"tag_name":"v2026.9.33","name":"n","published_at":"2026-10-15T10:39:22Z","html_url":"u"},"compare":{"status":null}}')"
	run jq -e '.anchor_ahead == false' <<< "$output"
	[ "$status" -eq 0 ]
}

# --- sig_diff ---------------------------------------------------------------

@test "sig_diff: no changed fields -> empty output" {
	run sig_diff '{"state":"open","ci":"failure"}' '{"state":"open","ci":"failure"}'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "sig_diff: reports each changed field once, skips title/url" {
	run sig_diff '{"state":"open","ci":"failure","approved":false,"title":"same","url":"same"}' '{"state":"open","ci":"success","approved":true,"title":"same","url":"same"}'
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | grep -c '• ci:')" = "1" ]
	[ "$(printf '%s\n' "$output" | grep -c '• approved:')" = "1" ]
	run grep -q 'title:' <<< "$output"
	[ "$status" -ne 0 ]
}

# --- unblocked (#176080 blocker-label removal) -----------------------------

@test "unblocked: true when no blocker labels present" {
	run unblocked '{"state":"open","labels":["P1","clawsweeper:source-repro"]}' "clawsweeper:no-new-fix-pr,needs-maintainer-review"
	[ "$status" -eq 0 ]
}

@test "unblocked: false when a blocker label is still present" {
	run unblocked '{"state":"open","labels":["clawsweeper:no-new-fix-pr","needs-maintainer-review"]}' "clawsweeper:no-new-fix-pr,needs-maintainer-review"
	[ "$status" -ne 0 ]
}

@test "unblocked: false when only one blocker remains" {
	run unblocked '{"state":"open","labels":["needs-maintainer-review"]}' "clawsweeper:no-new-fix-pr,needs-maintainer-review"
	[ "$status" -ne 0 ]
}

# --- item list is valid JSON and carries the expected keys/values -----------

# NOTE: openclaw/openclaw#176063 is CLOSED-COMPLETED (fix already merged
# upstream), so it is intentionally NOT in the gateway watch list -- no
# transition remains to observe there. The list is therefore six items
# (2 PRs + 3 issues + 1 release), not the seed's seven.

@test "items file: valid JSON with six watched items + anchor" {
	run jq -e '.upstream_repo == "openclaw/openclaw" and .anchor_commit == "607aabf8041" and (.items | length) == 6' \
		"$BATS_TEST_DIRNAME/../config/upstream-watch-items.json"
	[ "$status" -eq 0 ]
}

@test "items file: #176080 (issue) carries both unblock_labels" {
	run jq -e '.items[] | select(.number == 176080) | (.unblock_labels | index("clawsweeper:no-new-fix-pr") != null and index("needs-maintainer-review") != null)' \
		"$BATS_TEST_DIRNAME/../config/upstream-watch-items.json"
	[ "$status" -eq 0 ]
}

@test "items file: two PRs + three issues + one release" {
	run jq -e '[.items[] | select(.kind == "pr")] | length == 2' "$BATS_TEST_DIRNAME/../config/upstream-watch-items.json"
	[ "$status" -eq 0 ]
	run jq -e '[.items[] | select(.kind == "issue")] | length == 3' "$BATS_TEST_DIRNAME/../config/upstream-watch-items.json"
	[ "$status" -eq 0 ]
	run jq -e '[.items[] | select(.kind == "release")] | length == 1' "$BATS_TEST_DIRNAME/../config/upstream-watch-items.json"
	[ "$status" -eq 0 ]
}