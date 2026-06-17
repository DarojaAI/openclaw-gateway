#!/bin/bash
# install-openrouter-provisioning.sh
#
# Installs the OpenRouter provisioning key into the gateway's
# systemd user unit so the openrouter-provision.py CLI can find it
# at runtime. Idempotent: re-running with the same key is a no-op;
# re-running with a different key updates the override.
#
# Does NOT call the OpenRouter API itself — that is the deploy-time
# responsibility of the seed's configure-openclaw-agent.sh script,
# which invokes ``openrouter-provision.py sync`` with the agent
# list and writes the resulting per-agent keys into
# ``~/.openclaw/agents/<id>/agent/auth-profiles.json``.
#
# Key source (in order of precedence):
#   1. $OPENROUTER_PROVISIONING_KEY env var
#   2. /etc/openclaw/provisioning.key (mode 0600, root-owned)
#
# The script never logs or echoes the key material. It writes the
# value to the systemd override and confirms only that the override
# file now contains the assignment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR is exported for downstream tooling that sources this
# installer (e.g. the seed's deploy wrapper that wants to log which
# installer ran). Exporting it also keeps shellcheck happy.
export SCRIPT_DIR

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# Configurable paths. The user unit name and the override directory
# are the standard systemd-user locations; the key file is the
# location the seed's deploy pipeline (or a manual ``sudo install``
# step) is expected to write to on a fresh VM.
SERVICE_NAME="${OPENCLAW_GATEWAY_SERVICE:-openclaw-gateway.service}"
OVERRIDE_DIR="${HOME}/.config/systemd/user/${SERVICE_NAME}.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
KEY_FILE="${OPENROUTER_PROVISIONING_KEY_FILE:-/etc/openclaw/provisioning.key}"

# ── resolve the key ──────────────────────────────────────────────
#
# We never echo the value once loaded. We pass it directly to
# install_override() which writes it into the override file with
# ``install -m 0600`` semantics on the resulting file (we set the
# mode after writing). The value stays in the shell variable
# ``$key`` only.

key=""
if [ -n "${OPENROUTER_PROVISIONING_KEY:-}" ]; then
	key="${OPENROUTER_PROVISIONING_KEY}"
	log_info "Using OPENROUTER_PROVISIONING_KEY from environment"
elif [ -r "$KEY_FILE" ]; then
	key="$(cat "$KEY_FILE")"
	log_info "Using provisioning key from $KEY_FILE"
else
	log_error "No OPENROUTER_PROVISIONING_KEY env var and $KEY_FILE is not readable."
	log_error "Set OPENROUTER_PROVISIONING_KEY in the environment or write the key to $KEY_FILE (chmod 0600)."
	exit 2
fi

if [ -z "$key" ]; then
	log_error "Resolved provisioning key is empty; refusing to install an empty override."
	exit 2
fi

# ── write the override ───────────────────────────────────────────
#
# We use ``install -d`` for the directory so the mode is set in one
# step (mkdir + chmod is two steps and can leave the dir world-
# readable between them). For the file, we use a heredoc into a
# temp file, then ``install -m 0600`` to atomically place it.
# The 0600 mode matches the security model in
# docs/concepts/per-agent-openrouter-keys.md: the master key is
# only readable by the owning user.

install_override() {
	local value="$1"
	install -d -m 0700 "$OVERRIDE_DIR"
	local tmp
	tmp="$(mktemp "${OVERRIDE_DIR}/.override.conf.XXXXXX")"
	trap 'rm -f "$tmp"' EXIT
	{
		echo "# Managed by scripts/install/install-openrouter-provisioning.sh"
		echo "# Do not edit by hand — re-run the installer to update."
		echo "Environment=OPENROUTER_PROVISIONING_KEY=${value}"
	} >"$tmp"
	# install -m 0600 sets the mode and renames atomically. We do
	# NOT use ``cp`` because a 0400 dest would fail under cp 8.32
	# (see the 2026-06-09 deploy-snapshot postmortem in the seed
	# repo for the same pattern).
	install -m 0600 "$tmp" "$OVERRIDE_FILE"
	rm -f "$tmp"
	trap - EXIT
}

# Idempotency check. If the override already contains a non-empty
# OPENROUTER_PROVISIONING_KEY and we are not explicitly asked to
# rotate it (the env var is set, so a new value is intended), we
# leave the file alone. If the env var is set, the caller wants an
# update; if only the key file is set, we compare and update only
# on change to keep ``daemon-reload`` calls minimal.

needs_update() {
	local new_value="$1"
	if [ ! -f "$OVERRIDE_FILE" ]; then
		return 0
	fi
	# Extract the existing value, if any. We use a literal match
	# rather than source-parsing the .conf — systemd override files
	# are simple KEY=VALUE pairs.
	local current
	current="$(grep -E '^Environment=OPENROUTER_PROVISIONING_KEY=' "$OVERRIDE_FILE" 2>/dev/null | tail -n 1 | sed -E 's/^Environment=OPENROUTER_PROVISIONING_KEY=//')"
	if [ -z "$current" ]; then
		return 0
	fi
	if [ "$current" = "$new_value" ]; then
		return 1
	fi
	return 0
}

if needs_update "$key"; then
	log_info "Writing provisioning key override to $OVERRIDE_FILE"
	install_override "$key"
else
	log_info "Provisioning key already present in $OVERRIDE_FILE and matches; leaving it in place"
fi

# ── reload systemd user daemon ───────────────────────────────────
#
# We use ``systemctl --user daemon-reload`` so the next service
# start picks up the new Environment= line. We do NOT restart the
# gateway here: the deploy pipeline does that after rewriting
# auth-profiles.json for each agent. A restart with the new env
# but old auth-profiles.json would be a no-op anyway.

if command -v systemctl >/dev/null 2>&1; then
	if systemctl --user daemon-reload 2>/dev/null; then
		log_info "systemd user daemon reloaded"
	else
		# Fall back to the system daemon if user dbus isn't
		# reachable (common in CI sandboxes). The user unit will
		# still pick up the override when next started by the
		# real user session.
		log_warn "systemctl --user daemon-reload failed; the override is in place but the running daemon did not reload"
	fi
else
	log_warn "systemctl not on PATH; the override is in place but you will need to run 'systemctl --user daemon-reload' manually"
fi

# ── final confirmation (without leaking the key) ─────────────────

if [ -f "$OVERRIDE_FILE" ] && grep -q '^Environment=OPENROUTER_PROVISIONING_KEY=.' "$OVERRIDE_FILE"; then
	log_info "Override installed: $OVERRIDE_FILE contains OPENROUTER_PROVISIONING_KEY=<redacted>"
else
	log_error "Override verification failed: $OVERRIDE_FILE does not contain a non-empty OPENROUTER_PROVISIONING_KEY="
	exit 1
fi
