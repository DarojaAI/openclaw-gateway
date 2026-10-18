#!/usr/bin/env bash
# scripts/ci/upstream-watch.sh
#
# Hourly upstream-watch for the fork-drain queue (gateway#157).
#
# GATEWAY-NATIVE COMMENT TWIN of seed PR #2384. This script runs inside the
# gateway repo (openclaw-gateway), so its repo-scoped GITHUB_TOKEN can comment
# directly on DarojaAI/openclaw-gateway#157 -- dissolving the cross-repo PAT
# limitation documented in the seed PR (the seed's watcher remains for
# seed-side tracking; this one posts native comments on gateway#157).
#
# Watches a data-driven list of openclaw/openclaw PRs + issues (and the
# upstream latest release) for the transitions that unblock or move the
# fork-fix drain:
#
#   * PRs:  CI conclusion flipping to success, a new review APPROVAL, merge,
#           or close-without-merge.
#   * issues: state change, a new maintainer/codex comment (a `clawsweeper*`
#           label present on the issue, or a new comment from the
#           clawsweeper/codex bot), and NEW linked PRs (cross-referenced /
#           connected timeline events pointing at a PR in the upstream repo).
#   * issue #176080 specifically: the UNBLOCK signal = both blocker labels
#           (`clawsweeper:no-new-fix-pr`, `needs-maintainer-review`) REMOVED.
#   * releases: the latest upstream release tag changed (simple check); a
#           best-effort `anchor_ahead` flag records whether the anchor commit
#           (UPSTREAM_ANCHOR) is an ancestor of the new tag's commit.
#
# The watched-item list lives in $ITEMS_FILE (config/upstream-watch-items.json);
# adding an item is a one-line JSON change (the workflow passes it through).
#
# Per-item state is normalized to a stable signature JSON; a change is a
# signature mismatch vs the last-seen state file. On any change (and not in
# DRY_RUN) a concise comment is posted to the gateway tracking issue #157
# ($NOTIFY_REPO / $NOTIFY_ISSUE). NOTIFY_ISSUE defaults to 157 and is reused
# explicitly rather than create-new, so comments always land on gateway#157.
# If NOTIFY_ISSUE is unset (local/dry runs), the script falls back to a
# find-by-title lookup and then reuses #157 if none is found -- never creates
# a fresh tracking issue for a gateway-native run.
#
# The pure normalize/diff logic is BATS-tested (tests/upstream-watch.bats):
# gh is only invoked inside the *_payload() fetchers and main().
#
# Exit codes: 0 run clean (changes may or may not have been posted);
#             1 hard failure (jq absent, or a gh query errored -- fail loud,
#               never a silent green).

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (env-overridable so BATS and CI can inject values)
# ---------------------------------------------------------------------------
UPSTREAM_REPO="${UPSTREAM_REPO:-openclaw/openclaw}"
UPSTREAM_ANCHOR="${UPSTREAM_ANCHOR:-607aabf8041}"
ITEMS_FILE="${ITEMS_FILE:-config/upstream-watch-items.json}"
STATE_FILE="${STATE_FILE:-}"
GH_TOKEN="${GH_TOKEN:-}"
# The repo that owns the tracking issue (gateway repo). Defaults to the
# current repository. GITHUB_TOKEN is scoped to this repo, and here that is
# exactly what we want: gateway#157 lives in this repo, so the repo-scoped
# token can write the comment natively (this is the native-comment twin of
# seed PR #2384).
NOTIFY_REPO="${NOTIFY_REPO:-${GITHUB_REPOSITORY:-}}"
# The tracking issue number to comment on. Reused explicitly (gateway#157)
# rather than create-new; fall back to find-by-title then #157 when unset.
NOTIFY_ISSUE="${NOTIFY_ISSUE:-157}"
NOTIFY_ISSUE_TITLE="${NOTIFY_ISSUE_TITLE:-Upstream watch: openclaw fork-drain queue}"
DRY_RUN="${DRY_RUN:-false}"

command -v jq >/dev/null 2>&1 || { echo "upstream-watch: jq is required" >&2; exit 1; }

# ghq <repo>/<path> -- run gh api against the upstream repo, fail LOUD on error.
ghq() {
	local path="$1" out
	out="$(gh api "/repos/${path}")" || {
		local rc=$?
		echo "::error::upstream-watch: gh api failed: /repos/${path} (rc=${rc})" >&2
		exit 1
	}
	printf '%s\n' "$out"
}

# ghq_upstream <path> -- ghq against UPSTREAM_REPO.
ghq_upstream() {
	local path="$1"
	ghq "${UPSTREAM_REPO}/${path}"
}

# ---------------------------------------------------------------------------
# Pure normalize logic (BATS-tested; no gh, no filesystem)
# ---------------------------------------------------------------------------

# ci_summary <raw-check-runs-json-or-file> -- derive a single CI verdict from
# a `check-runs` payload. Accepts either an inline JSON string (small; BATS)
# or a file path (production; the check-runs list can be large, over the
# kernel per-arg limit). Robust to both the REST `{check_runs:[...]}` wrapper
# and a bare array. Verdict order: failure > pending > success > unknown.
ci_summary() {
	local raw="$1"
	jq_filter='[ (.check_runs? // . // []) ] | .[0] as $rs
		| if ($rs | length) == 0 then "unknown"
		  else
			[ $rs[] | select(.status == "completed") | .conclusion ] as $done
			| if ([ $done[] | select(. == "failure" or . == "cancelled" or . == "timed_out" or . == "action_required") ] | length) > 0 then "failure"
			  elif ([ $rs[] | select(.status != "completed") ] | length) > 0 then "pending"
			  elif ([ $done[] | select(. != "success" and . != "neutral" and . != "skipped") ] | length) == 0 then "success"
			  else "unknown"
			  end
		  end'
	if [[ -f "$raw" ]]; then
		jq -r "$jq_filter" "$raw"
	else
		printf '%s' "$raw" | jq -r "$jq_filter"
	fi
}

# normalize_pr <payload-file> -- payload = {pull, reviews, checks}; echoes the
# stable signature JSON (title/url retained for rich comments).
normalize_pr() {
	jq -c '
		{ state: .pull.state,
		  merged: .pull.merged,
		  approved: ([ .reviews[] | select(.state == "APPROVED") ] | length > 0),
		  approved_count: ([ .reviews[] | select(.state == "APPROVED") ] | length),
		  ci: ("placeholder"),
		  title: .pull.title,
		  url: .pull.html_url }' "$1"
}

# normalize_pr_ci <payload-file> -- normalize_pr with the real CI verdict wired
# in (production path; normalize_pr is only kept for parity/clarity).
normalize_pr_ci() {
	local ci base
	base="$(mktemp -d "${YQ_TMPDIR}/uw-prci.XXXXXX")"
	jq -r '.checks' "$1" > "$base/checks.json"
	ci="$(ci_summary "$base/checks.json")"
	jq -c --arg ci "$ci" '
		{ state: .pull.state,
		  merged: .pull.merged,
		  approved: ([ .reviews[] | select(.state == "APPROVED") ] | length > 0),
		  approved_count: ([ .reviews[] | select(.state == "APPROVED") ] | length),
		  ci: $ci,
		  title: .pull.title,
		  url: .pull.html_url }' "$1"
	rm -rf "$base"
}

# normalize_issue <payload-file> -- payload = {issue, comments(desc), timeline};
# echoes the issue signature JSON. linked_prs = cross-referenced/connected
# timeline events whose source is a PR (has pull_request) in UPSTREAM_REPO.
normalize_issue() {
	jq -c --arg upstream "$UPSTREAM_REPO" '
		. as $p
		| ([ $p.issue.labels[] | .name ]) as $labels
		| ([ $p.timeline[]
		     | select((.event == "cross-referenced" or .event == "connected")
		              and ((.source.issue.repository.full_name // .source.repository.full_name // "") == $upstream)
		              and ((.source.issue.pull_request // null) != null)) ]) as $prs
		| { state: $p.issue.state,
		    labels: $labels,
		    clawsweeper_label: ([ $labels[] | select(startswith("clawsweeper")) ] | length > 0),
		    latest_comment_id: ($p.comments[0].id // null),
		    latest_comment_author: ($p.comments[0].user.login // null),
		    comment_count: ($p.comments | length),
		    linked_prs: ($prs | length),
		    title: $p.issue.title,
		    url: $p.issue.html_url }' "$1"
}

# normalize_release <payload-file> -- payload = {release, compare}; echoes the
# release signature JSON.
normalize_release() {
	jq -c '
		. as $p
		| { latest_tag: $p.release.tag_name,
		    anchor_ahead: ((($p.compare.status // "unknown") == "ahead") or (($p.compare.status // "unknown") == "identical")),
		    name: $p.release.name,
		    published_at: ($p.release.published_at // null),
		    url: $p.release.html_url }' "$1"
}

# sig_diff <old-sig-json> <new-sig-json> -- echoes "• field: old → new" lines
# for every field that changed between two signatures of the same kind.
# Empty labels arrays render compactly (label sigs carry the full label list;
# an added label shows as a short "…+N" instead of a full array dump).
sig_diff() {
	printf '%s' "$2" | jq -r --argjson old "$1" '
		def render($v):
			if $v == null then "∅"
			elif ($v | type) == "array" then
				if ($v | length) == 0 then "[]"
				else "[" + (($v | join(","))) + "]"
				end
			else ($v | tostring)
			end;
		keys[] as $k
		| select($k != "title" and $k != "url")
		| select((($old[$k] | (. == null)) != (.[$k] | (. == null)))
		          or (($old[$k] // null) != (.[$k] // null)))
		| "• \($k): \(render($old[$k])) → \(render(.[$k]))"'
}

# unblocked <sig-json> <blockers-csv> -- 0 (true) when the signature carries
# NONE of the given blocker labels (the #176080 unblock condition).
unblocked() {
	local sig="$1" blockers="$2" present
	present="$(printf '%s' "$sig" | jq -r --arg blockers "$blockers" '
		[ ($blockers | split(","))[] as $b | .labels[] | select(. == $b) ] | length')"
	[[ "$present" == "0" ]]
}

# ---------------------------------------------------------------------------
# gh-backed fetchers (merge raw pieces into one payload for normalize_*)
# ---------------------------------------------------------------------------

# Payloads can be large (timeline + check-runs), far over the kernel per-arg
# limit, so they are merged through FILES (jq --slurpfile) instead of argv
# (--argjson "Argument list too long" on pr/issue payloads). Each builder
# writes its raw pieces to $YQ_TMPDIR and emits the combined payload on
# stdout.
YQ_TMPDIR="${YQ_TMPDIR:-${TMPDIR:-/tmp}}"

# pr_payload <number> -- {pull, reviews, checks}
pr_payload() {
	local n="$1" base
	base="$(mktemp -d "${YQ_TMPDIR}/uw-pr.XXXXXX")"
	ghq_upstream "pulls/${n}" > "$base/pull.json"
	ghq_upstream "pulls/${n}/reviews?per_page=100" > "$base/reviews.json"
	local head_sha
	head_sha="$(jq -r '.head.sha // empty' "$base/pull.json")"
	if [[ -n "$head_sha" ]]; then
		ghq_upstream "commits/${head_sha}/check-runs?per_page=100" > "$base/checks.json"
	else
		printf '%s\n' '{"check_runs":[]}' > "$base/checks.json"
	fi
	jq -n --slurpfile pull "$base/pull.json" --slurpfile reviews "$base/reviews.json" \
		--slurpfile checks "$base/checks.json" \
		'{pull: $pull[0], reviews: $reviews[0], checks: $checks[0]}'
	rm -rf "$base"
}

# issue_payload <number> -- {issue, comments(desc), timeline}
issue_payload() {
	local n="$1" base
	base="$(mktemp -d "${YQ_TMPDIR}/uw-issue.XXXXXX")"
	ghq_upstream "issues/${n}" > "$base/issue.json"
	ghq_upstream "issues/${n}/comments?per_page=100&sort=created&direction=desc" > "$base/comments.json"
	ghq_upstream "issues/${n}/timeline?per_page=100" > "$base/timeline.json"
	jq -n --slurpfile issue "$base/issue.json" --slurpfile comments "$base/comments.json" \
		--slurpfile timeline "$base/timeline.json" \
		'{issue: $issue[0], comments: $comments[0], timeline: $timeline[0]}'
	rm -rf "$base"
}

# release_payload -- {release, compare}; compare = anchor..latest-tag ancestry.
release_payload() {
	local base release tag
	base="$(mktemp -d "${YQ_TMPDIR}/uw-rel.XXXXXX")"
	ghq_upstream "releases/latest" > "$base/release.json"
	tag="$(jq -r '.tag_name // empty' "$base/release.json")"
	if [[ -n "$tag" ]]; then
		# Best-effort ancestry: if the compare 404s (tag not in default
		# history) we still report the tag change; anchor_ahead stays
		# "unknown". A compare failure is expected enough here NOT to fail
		# loud (the tag-change itself is the load-bearing signal).
		gh api "/repos/${UPSTREAM_REPO}/compare/${UPSTREAM_ANCHOR}...${tag}" 2>/dev/null \
			| jq '{status: (.status // null), ahead_by, behind_by}' > "$base/compare.json" \
			|| printf '%s\n' '{"status":null}' > "$base/compare.json"
	else
		printf '%s\n' '{"status":null}' > "$base/compare.json"
	fi
	jq -n --slurpfile release "$base/release.json" --slurpfile compare "$base/compare.json" \
		'{release: $release[0], compare: $compare[0]}'
	rm -rf "$base"
}

# ---------------------------------------------------------------------------
# State persistence (plain JSON file on disk; the workflow owns cache/commit)
# ---------------------------------------------------------------------------

# state_read <key> -- echo the previous signature for a key ("" if none).
state_read() {
	local key="$1"
	[[ -n "$STATE_FILE" && -f "$STATE_FILE" ]] || { printf ''; return; }
	jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || printf ''
}

# state_write <key> <sig-json> -- set a key in the state file (no-op without
# STATE_FILE; used for local runbook/testing outside a workflow).
state_write() {
	local key="$1" sig="$2"
	[[ -n "$STATE_FILE" ]] || return 0
	if [[ ! -f "$STATE_FILE" ]]; then
		printf '{}\n' > "$STATE_FILE"
	fi
	local tmp
	tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
	jq --arg k "$key" --argjson v "$sig" '.[$k] = $v' "$STATE_FILE" > "$tmp" \
		&& mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Notification surface: comment on gateway#157 (NOTIFY_ISSUE, reused #157 by
# default; find-by-title fallback -- never create-new for a gateway run).
# ---------------------------------------------------------------------------

# issue_exists <repo> <number> -- 0 when the issue opens OK without error.
issue_exists() {
	local repo="$1" num="$2"
	gh issue view "$num" --repo "$repo" --json number --jq '.number' >/dev/null 2>&1
}

# ensure_notify_issue -- echo the tracking issue number: NOTIFY_ISSUE (default
# 157) when live, else find-by-title in NOTIFY_REPO, else #157. Any failure
# to reach the notify surface is LOUD (::error:: + return 1): an
# upstream-watch that has detected changes but cannot reach its notify
# surface is a silent green. We never CREATE a tracking issue for a
# gateway-native run (gateway#157 is the fixed destination) -- NOTIFY_ISSUE
# is reused explicitly rather than create-new.
ensure_notify_issue() {
	[[ -n "$NOTIFY_REPO" && -n "$GH_TOKEN" ]] || {
		echo "::error::upstream-watch: NOTIFY_REPO/GH_TOKEN unset; cannot notify" >&2
		return 1
	}
	command -v gh >/dev/null 2>&1 || {
		echo "::error::upstream-watch: gh not installed" >&2
		return 1
	}
	# Best-effort label ensure (mirrors branch-divergence's ensure_label): a
	# first run on a fresh repo will not have NOTIFY_LABEL yet; issues:write
	# is enough to create it. Failure to create is non-fatal (label is a
	# nicety; the issue + comment still land).
	if [[ -n "${NOTIFY_LABEL:-}" ]]; then
		gh label create "$NOTIFY_LABEL" --repo "$NOTIFY_REPO" \
			--color B60205 --description "Auto-maintained by upstream-watch cron" \
			>/dev/null 2>&1 || true
	fi
	# NOTIFY_ISSUE is the fixed destination (gateway#157); reuse it unless a
	# caller pinned it to an absent/closed number (then fall through to the
	# find-by-title lookup so the run still lands somewhere useful).
	if [[ -n "${NOTIFY_ISSUE:-}" ]] && issue_exists "$NOTIFY_REPO" "$NOTIFY_ISSUE"; then
		printf '%s\n' "$NOTIFY_ISSUE"
		return 0
	fi
	local existing
	existing="$(gh issue list --repo "$NOTIFY_REPO" --state open \
		--search "in:title \"${NOTIFY_ISSUE_TITLE}\"" \
		--json number,title --jq '.[0].number // empty' 2>/dev/null || true)"
	if [[ -n "$existing" ]]; then
		printf '%s\n' "$existing"
		return 0
	fi
	# Reuse #157 explicitly, never create-new (gateway-native destination).
	printf '%s\n' '157'
}

# post_comment <issue-number> <body> -- add a change comment to the tracking
# issue; fails loud on error (the notification is the point of the run).
post_comment() {
	local issue="$1" body="$2"
	[[ -n "$issue" && -n "$GH_TOKEN" ]] || { echo "::error::upstream-watch: cannot post comment (no issue/token)" >&2; return 1; }
	if ! gh issue comment "$issue" --repo "$NOTIFY_REPO" --body "$body" >/dev/null; then
		echo "::error::upstream-watch: failed to comment on #${issue} in ${NOTIFY_REPO}" >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	[[ -n "$GH_TOKEN" || "$DRY_RUN" == "true" ]] || {
		echo "upstream-watch: GH_TOKEN is required (or set DRY_RUN=true)" >&2
		echo "upstream-watch: continuing to emit summary without posting" >&2
	}

	command -v gh >/dev/null 2>&1 || {
		echo "upstream-watch: gh not installed" >&2
		return 1
	}
	[[ -f "$ITEMS_FILE" ]] || { echo "upstream-watch: items file not found: ${ITEMS_FILE}" >&2; return 1; }

	local -a changes=()
	local item kind num name unblock new_sig old_sig key diff_lines payload_file
	# DRY_RUN never advances the baseline: read already-cached state but do
	# not mutate it, so a dry-run pass reports transitions against the last
	# REAL run instead of inventing one.
	local persist
	persist=no
	[[ "$DRY_RUN" != "true" ]] && persist=yes

	# --- per-item watch ---------------------------------------------------
	while IFS= read -r item; do
		[[ -n "$item" ]] || continue
		kind="$(printf '%s' "$item" | jq -r '.kind')"
		num="$(printf '%s' "$item" | jq -r '.number // empty')"
		name="$(printf '%s' "$item" | jq -r '.name // empty')"
		key="${kind}:${num:-latest}"

		# Materialize the payload to a real file: normalize_* read their input
		# >= once, so a one-shot process-substitution pipe is not safe.
		payload_file="$(mktemp "${YQ_TMPDIR}/uw-payload.XXXXXX.json")"
		case "$kind" in
			pr)
				old_sig="$(state_read "$key")"
				pr_payload "$num" > "$payload_file"
				new_sig="$(normalize_pr_ci "$payload_file")"
				;;
			issue)
				old_sig="$(state_read "$key")"
				issue_payload "$num" > "$payload_file"
				new_sig="$(normalize_issue "$payload_file")"
				;;
			release)
				old_sig="$(state_read "$key")"
				release_payload > "$payload_file"
				new_sig="$(normalize_release "$payload_file")"
				;;
			*)
				echo "::warning::upstream-watch: unknown item kind '${kind}' in ${ITEMS_FILE}" >&2
				rm -f "$payload_file"
				continue
				;;
		esac
		rm -f "$payload_file"

		# Unblock signal for the blockers-carrying issue (kind issue only).
		if [[ "$kind" == "issue" && -n "$old_sig" && -n "$new_sig" ]]; then
			local blockers
			blockers="$(printf '%s' "$item" | jq -r '[.unblock_labels[]?] | join(",")')"
			if [[ -n "$blockers" ]]; then
				local was_blocked now_unblocked
				was_blocked=no; now_unblocked=no
				unblocked "$old_sig" "$blockers" && was_blocked=no || was_blocked=yes
				unblocked "$new_sig" "$blockers" && now_unblocked=yes || now_unblocked=no
				if [[ "$was_blocked" == "yes" && "$now_unblocked" == "yes" ]]; then
					changes+=("UNBLOCK: issue ${num} — both blocker labels (${blockers//,/ }) removed")
				fi
			fi
		fi

		if [[ -z "$old_sig" ]]; then
			echo "upstream-watch: ${key}: first observation (baseline), no change reported"
			[[ "$persist" == "yes" ]] && state_write "$key" "$new_sig"
			continue
		fi

		if [[ "$old_sig" == "$new_sig" ]]; then
			echo "upstream-watch: ${key}: unchanged"
			continue
		fi

		diff_lines="$(sig_diff "$old_sig" "$new_sig")"
		if [[ -n "$diff_lines" ]]; then
			changes+=("${kind^^} ${num} — ${name:+${name}. }changed")
			while IFS= read -r l; do [[ -n "$l" ]] && changes+=("  ${l}"); done <<< "$diff_lines"
		fi
		[[ "$persist" == "yes" ]] && state_write "$key" "$new_sig"
	done < <(jq -c '.items[]' "$ITEMS_FILE")

	# --- report ------------------------------------------------------------
	{
		echo "## Upstream-watch summary (gateway#157)"
		echo
		echo "Checked ${UPSTREAM_REPO} release + $(jq '.items | length' "$ITEMS_FILE") item(s)."
		if [[ "${#changes[@]}" -gt 0 ]]; then
			echo
			echo "### Changes detected"
			printf -- '- %s\n' "${changes[@]}"
		else
			echo
			echo "No changes detected this run."
		fi
	} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

	for row in "${changes[@]}"; do printf '%s\n' "$row"; done

	if [[ "${#changes[@]}" -eq 0 || "$DRY_RUN" == "true" ]]; then
		return 0
	fi

	# --- notify (skip when dry-run) -----------------------------------------
	local issue body
	if ! issue="$(ensure_notify_issue)"; then
		echo "::error::upstream-watch: could not resolve the tracking issue; no comment posted" >&2
		return 1
	fi
	body="$(printf 'Upstream-watch detected changes for the fork-drain queue (checked at %s UTC):\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")$(printf -- '- %s\n' "${changes[@]}")"
	if ! post_comment "$issue" "$body"; then
		echo "::error::upstream-watch: comment to #${issue} failed; changes went unreported" >&2
		return 1
	fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi