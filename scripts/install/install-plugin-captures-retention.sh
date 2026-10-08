#!/usr/bin/env bash
# scripts/install/install-plugin-captures-retention.sh
#
# Installs the plugin-captures retention user systemd timer + service.
#
# What this installs:
#   - ~/.config/systemd/user/openclaw-plugin-captures-retention.service
#   - ~/.config/systemd/user/openclaw-plugin-captures-retention.timer
#   - ~/.local/bin/openclaw-plugin-captures-prune  (symlink to repo script)
#
# Why this exists:
# The upstream OpenClaw runtime stages a full capture per plugin-admission
# event under ~/.openclaw/tmp/plugin-captures/<uuid>/ (native plugin package
# copies + an owner.sqlite snapshot) and never prunes them — ~1.8 GiB/day
# observed on prod (this repo issue #134; upstream openclaw/openclaw#167480).
# This timer bounds the footprint at the L3b layer until the runtime grows
# native retention.
#
# Behavior:
#   - Daily oneshot; dry-run is NOT used here: the timer deletes for real.
#     Tune or disable via the env vars below.
#   - Knobs (baked into the unit at install time):
#       OPENCLAW_PLUGIN_CAPTURES_MAX_AGE_DAYS (default 2)
#       OPENCLAW_PLUGIN_CAPTURES_MAX_BYTES     (default 2G)
#   - Honors $HOME so BATS tests can install into a fake home.
#   - Idempotent: re-runs overwrite the units and reload.
#   - Refuses to enable if systemd --user is not available.
#
# Exit codes:
#   0 = installed and enabled
#   1 = install failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# ---- Knobs -----------------------------------------------------------------

# Knobs live in an env-file so operators can retune without reinstalling.
# The installer writes the defaults once; it never overwrites an existing
# file. The pruner reads these exact var names as CLI-flag fallbacks.
ENV_FILE="$HOME/.openclaw/plugin-captures-retention.env"
MAX_AGE_DAYS="${OPENCLAW_PLUGIN_CAPTURES_MAX_AGE_DAYS:-2}"
MAX_BYTES="${OPENCLAW_PLUGIN_CAPTURES_MAX_BYTES:-2G}"

if [[ ! -f "$ENV_FILE" ]]; then
	cat > "$ENV_FILE" <<EOF
# Tuning for openclaw-plugin-captures-retention.service (systemctl --user
# daemon-reload + restart the service after editing).
PRUNE_MAX_AGE_DAYS=${MAX_AGE_DAYS}
PRUNE_MAX_BYTES=${MAX_BYTES}
EOF
	chmod 0644 "$ENV_FILE"
	log_info "Wrote knobs file: $ENV_FILE (defaults max-age=${MAX_AGE_DAYS}d, max-bytes=${MAX_BYTES})"
else
	log_info "Knobs file exists, left untouched: $ENV_FILE"
fi

# ---- Preconditions ---------------------------------------------------------

if ! command -v systemctl >/dev/null 2>&1; then
    log_error "systemctl not found; cannot install user timer"
    exit 1
fi

if [[ -z "${HOME:-}" ]]; then
    log_error "HOME is not set; refusing to install"
    exit 1
fi

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
mkdir -p "$HOME/.local/bin"

PRUNE_SRC="$REPO_ROOT/scripts/lib-prune-retention.py"
if [[ ! -f "$PRUNE_SRC" ]]; then
    log_error "Pruner not found at $PRUNE_SRC"
    exit 1
fi

# ---- Symlink the script ----------------------------------------------------

PRUNE_DST="$HOME/.local/bin/openclaw-plugin-captures-prune"
if [[ -L "$PRUNE_DST" ]] || [[ -f "$PRUNE_DST" ]]; then
    rm -f "$PRUNE_DST"
fi
ln -s "$PRUNE_SRC" "$PRUNE_DST"
chmod +x "$PRUNE_SRC" || true
log_info "Linked pruner: $PRUNE_DST -> $PRUNE_SRC"

# ---- Write systemd units ---------------------------------------------------

SERVICE_FILE="$SYSTEMD_USER_DIR/openclaw-plugin-captures-retention.service"
TIMER_FILE="$SYSTEMD_USER_DIR/openclaw-plugin-captures-retention.timer"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=OpenClaw plugin-captures retention prune
Documentation=https://github.com/DarojaAI/openclaw-gateway

[Service]
Type=oneshot
EnvironmentFile=%h/.openclaw/plugin-captures-retention.env
ExecStart=/bin/sh -c 'exec %h/.local/bin/openclaw-plugin-captures-prune --dir %h/.openclaw/tmp/plugin-captures --max-age-days "\$PRUNE_MAX_AGE_DAYS" --max-bytes "\$PRUNE_MAX_BYTES" --delete'
StandardOutput=append:%h/.local/log/openclaw-plugin-captures/prune.log
StandardError=append:%h/.local/log/openclaw-plugin-captures/prune.log
EOF

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=OpenClaw plugin-captures retention (daily)

[Timer]
OnCalendar=daily
Persistent=true
Unit=openclaw-plugin-captures-retention.service

[Install]
WantedBy=default.target
EOF

mkdir -p "$HOME/.local/log/openclaw-plugin-captures"
touch "$HOME/.local/log/openclaw-plugin-captures/prune.log"
chmod 0644 "$HOME/.local/log/openclaw-plugin-captures/prune.log"

# ---- Enable + start --------------------------------------------------------

systemctl --user daemon-reload
systemctl --user enable --now openclaw-plugin-captures-retention.timer

log_info "Installed and enabled openclaw-plugin-captures-retention.timer (max-age=${MAX_AGE_DAYS}d, max-bytes=${MAX_BYTES})"
