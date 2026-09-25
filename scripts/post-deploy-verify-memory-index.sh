#!/usr/bin/env bash
# scripts/post-deploy-verify-memory-index.sh
#
# Post-deploy health gate: refuses to declare a deploy healthy if any
# agent's memory index is in a degraded state (metadata missing, provider
# mismatch, etc.) on a deploy that previously had data to index.
#
# Called at the end of scripts/install/deploy.sh (via L3a's deploy
# pipeline). Runs `openclaw memory status --json`, pipes through
# scripts/lib-parse-memory-status.py, and decides based on per-agent
# verdicts.
#
# Why this exists:
# The deploy pipeline's existing health check pings /healthz and the
# gateway process is up, but it does not look at the memory index. A
# freshly-deployed gateway can be "up" while the index is broken because
# the upstream OpenClaw runtime does not detect the condition at boot —
# the disable message only surfaces when an agent actually calls
# `memory_search`. Failing the deploy gate forces the operator to
# rebuild the index (`openclaw memory index --force`) before the deploy
# is considered healthy.
#
# Why this is L3b (not upstream):
# Upstream `openclaw/openclaw` owns the fix for the underlying
# provider/model race (PR #90453). This script is the L3b-layer
# detection + deploy-gate integration that catches regressions in the
# meantime, and complements PR #90453 by ensuring future regressions of
# the same shape are caught at the deploy boundary rather than at the
# next `memory_search` call.
#
# Exit codes:
#   0 = healthy (or fresh install with no data to index)
#   1 = at least one agent has a missing/mismatched memory identity
#       AND has data that should be indexed (deploy gate fails)
#   2 = probe failed: openclaw not on PATH, JSON parse error, no agents
#       returned by `openclaw memory status --json`
#
# Env:
#   SKIP_POST_DEPLOY_MEMORY_CHECK     if "1", skip the check entirely
#                                     (use for offline / debug deploys)
#   MEMORY_CHECK_FAIL_ON_FRESH        if "1", treat fresh installs
#                                     (zero chunks) as failures too —
#                                     useful for prod environments where
#                                     the index should always be built.
#                                     Default: 0 (WARN only on fresh)
#   MEMORY_CHECK_USER                  probe as this user instead of
#                                     auto-detecting the gateway service
#                                     user (owner of the running
#                                     openclaw.mjs process). Set when the
#                                     gateway is down or for offline
#                                     debugging of a specific user's store.
#
# Refs:
#   DarojaAI/openclaw-gateway#21      — index metadata missing
#   openclaw/openclaw#90361           — root-cause race
#   openclaw/openclaw#90453           — mergeable closing PR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/lib-parse-memory-status.py"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [post-deploy-verify-memory-index] $*" >&2; }

# ---- Opt-out ----------------------------------------------------------------
if [[ "${SKIP_POST_DEPLOY_MEMORY_CHECK:-0}" == "1" ]]; then
	log "Skipped (SKIP_POST_DEPLOY_MEMORY_CHECK=1)"
	exit 0
fi

# ---- Probe ------------------------------------------------------------------
if ! command -v openclaw >/dev/null 2>&1; then
	log "FAIL: openclaw binary not found on PATH"
	exit 2
fi

if [[ ! -f "$PARSER" ]]; then
	log "FAIL: parser not found at $PARSER"
	exit 2
fi
# ---- Probe as the gateway service user ------------------------------------
# The L3a pipeline invokes deploy.sh over ssh as root, but the gateway
# runs as an unprivileged desktop user; `openclaw memory status` reads
# $HOME-scoped state (per-agent sqlite + index sidecars). Probing as
# root inspects root's own (empty) store — agent "main" — which fails
# every deploy even when the deployed fleet is fully healthy
# (linux-desktop-seed run 36190247631, 2026-09-25). Resolve the user
# that owns the running gateway and probe as that user instead.
#
# Resolution order:
#   1. $MEMORY_CHECK_USER  — explicit override (debug / offline deploys)
#   2. owner of the running gateway process
#   3. the invoking user (previous behavior; safe when the gateway is
#      down or user detection is unavailable)
resolve_gateway_probe_user() {
	if [[ -n "${MEMORY_CHECK_USER:-}" ]]; then
		printf '%s\n' "$MEMORY_CHECK_USER"
		return 0
	fi
	local proc_root="${GATEWAY_PROC_ROOT:-/proc}"
	local pid cmd owner
	# pgrep is only the broad candidate filter here — an anchored
	# `pgrep -f '^openclaw-gateway$'` does not match reliably across
	# launch contexts, and an unanchored one matches deploy.sh's own
	# path under /opt/openclaw-gateway/ (and this gate's own script
	# path). Read /proc/<pid>/cmdline and require an exact match:
	#   - `openclaw-gateway` — the systemd user unit's process shape
	#   - `*openclaw.mjs*gateway*` — the `node .../openclaw.mjs gateway`
	#     launch shape
	# Casual `openclaw` CLI invocations (memory index, doctor) and
	# deploy.sh itself match neither, so a root-run deploy pipeline
	# still resolves to the unprivileged gateway owner.
	for pid in $(pgrep -f 'openclaw-gateway|openclaw\.mjs' 2>/dev/null || true); do
		cmd="$(tr -d '[:space:]' <"$proc_root/$pid/cmdline" 2>/dev/null || true)"
		if [[ "$cmd" == "openclaw-gateway" || "$cmd" == *openclaw.mjs*gateway* ]]; then
			owner="$(stat -c %U "$proc_root/$pid" 2>/dev/null || true)"
			if [[ -n "$owner" ]]; then
				printf '%s\n' "$owner"
				return 0
			fi
		fi
	done
	printf '%s\n' "$(id -un 2>/dev/null || echo root)"
}

# `openclaw memory status --json` returns a JSON array; one element per
# agent that has memory enabled. When the probe user differs from the
# invoking user, run the probe as the probe user (runuser sets HOME to
# the target user; XDG_RUNTIME_DIR lets the CLI reach the user bus for
# secret resolution).
probe_user="$(resolve_gateway_probe_user)"
invoker="$(id -un 2>/dev/null || echo root)"
probe_prefix=()
if [[ "$invoker" != "$probe_user" ]] && command -v runuser >/dev/null 2>&1; then
	probe_uid="$(id -u "$probe_user" 2>/dev/null || echo 0)"
	probe_prefix=(runuser -u "$probe_user" -- env "XDG_RUNTIME_DIR=/run/user/${probe_uid}")
	log "INFO: probing memory index as gateway user '${probe_user}' (invoked as '${invoker}')"
fi
status_json="$("${probe_prefix[@]}" openclaw memory status --json 2>/dev/null || true)"

if [[ -z "$status_json" ]]; then
	log "FAIL: openclaw memory status --json returned no output"
	exit 2
fi

# ---- Parse + decide ---------------------------------------------------------
# Run the parser once, capturing stdout (TSV rows) and stderr (a short
# classification tag) separately via a temp file. The parser's exit code
# is the canonical signal — non-zero means the input could not be
# turned into rows and the caller should treat this as a probe failure.
parse_err_file="$(mktemp)"
trap 'rm -f "$parse_err_file"' EXIT
parse_output="$(printf '%s' "$status_json" | python3 "$PARSER" 2>"$parse_err_file")" \
	|| parse_rc=$? || true
: "${parse_rc:=0}"
parse_err="$(head -1 "$parse_err_file" 2>/dev/null || true)"

if [[ "$parse_rc" -ne 0 ]]; then
	case "$parse_rc" in
		3)
			log "FAIL: JSON parse error from openclaw memory status:"
			[[ -n "$parse_err" ]] && printf '%s\n' "$parse_err" | sed 's/^/  /' >&2
			exit 2
			;;
		4)
			log "WARN: no agents reported by openclaw memory status — memory subsystem is empty"
			log "OK: nothing to verify (no agents bound yet)"
			exit 0
			;;
		*)
			log "FAIL: parser exited $parse_rc: $parse_err"
			exit 2
			;;
	esac
fi

# ---- Classify rows ----------------------------------------------------------
fails=()
warns=()
oks=()

while IFS=$'\t' read -r agent verdict reason; do
	[[ -z "$agent" ]] && continue
	case "$verdict" in
		ok) oks+=("$agent") ;;
		warn-fresh)
			if [[ "${MEMORY_CHECK_FAIL_ON_FRESH:-0}" == "1" ]]; then
				fails+=("$agent [$verdict, $reason]")
			else
				warns+=("$agent [$verdict, $reason]")
			fi
			;;
		warn-swap) warns+=("$agent [$verdict, $reason]") ;;
		fail) fails+=("$agent [$verdict, $reason]") ;;
		warn-unknown) warns+=("$agent [$verdict, $reason]") ;;
		*) log "WARN: unknown verdict '$verdict' for $agent" ;;
	esac
done <<<"$parse_output"

# ---- Report -----------------------------------------------------------------
for w in "${warns[@]:-}"; do
	[[ -n "$w" ]] && log "WARN: $w"
done

for ok in "${oks[@]:-}"; do
	[[ -n "$ok" ]] && log "OK: $ok"
done

if [[ ${#fails[@]} -gt 0 ]]; then
	log "FAIL: ${#fails[@]} agent(s) have a degraded memory index:"
	for f in "${fails[@]}"; do
		log "  - $f"
	done
	log ""
	log "Remediation:"
	log "  openclaw memory index --force"
	log ""
	log "Or via the deployed skill (preferred — works from Discord):"
	log "  /memory-rebuild"
	log ""
	log "After rebuild, re-run the deploy to confirm the gate passes."
	exit 1
fi

if [[ ${#oks[@]} -eq 0 ]] && [[ ${#warns[@]} -eq 0 ]]; then
	log "WARN: parser produced no rows; treating as probe failure"
	exit 2
fi

log "OK: memory index check passed — ${#oks[@]} healthy, ${#warns[@]} warn, ${#fails[@]} fail"
exit 0
