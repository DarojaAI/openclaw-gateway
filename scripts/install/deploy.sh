#!/bin/bash
# OpenClaw Gateway Self-Install
# Called by linux-desktop-seed deploy after cloning this repo to /tmp/openclaw-gateway
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

log_info "Installing OpenClaw Gateway from $REPO_ROOT"

# 1. Install OpenClaw binary (if not already installed)
if command -v openclaw &>/dev/null; then
    log_info "OpenClaw binary already installed"
else
    OPENCLAW_BIN="$REPO_ROOT/openclaw"
    if [[ -f "$OPENCLAW_BIN" ]]; then
        log_info "Installing OpenClaw binary..."
        chmod +x "$OPENCLAW_BIN"
        cp "$OPENCLAW_BIN" /usr/local/bin/openclaw
        log_info "OpenClaw binary installed"
    else
        log_warn "OpenClaw binary not found at $OPENCLAW_BIN"
    fi
fi

# 2. Install model manager globally
model_manager_src="$REPO_ROOT/scripts/openclaw-model-manager.py"
model_manager_dst="/usr/local/bin/openclaw-model-manager"
if [[ -f "$model_manager_src" ]]; then
    log_info "Installing OpenClaw model manager..."
    chmod +x "$model_manager_src"
    cp "$model_manager_src" "$model_manager_dst"
    log_info "Model manager installed to $model_manager_dst"
else
    log_warn "Model manager not found at $model_manager_src"
fi

# 3. Config is written by L3 (linux-desktop-seed) deploy pipeline
# L3b (this repo) owns canonical defaults in config/openclaw-defaults.json
# L3 writes the full config via merge-openclaw-config.py during deploy
# L2 (linux-desktop-setup) handles VM installation, not configuration

# 4. Install cost monitor companion script
cost_monitor_src="$REPO_ROOT/scripts/cost-monitor.py"
cost_monitor_dst="/usr/local/bin/openclaw-cost-monitor"
if [[ -f "$cost_monitor_src" ]]; then
    log_info "Installing OpenClaw cost monitor..."
    chmod +x "$cost_monitor_src"
    cp "$cost_monitor_src" "$cost_monitor_dst"
    log_info "Cost monitor installed to $cost_monitor_dst"
else
    log_warn "Cost monitor not found at $cost_monitor_src"
fi

# 4b. Install openrouter-provision CLI
#
# Why: the seed's configure-openclaw-agent.sh invokes
# /usr/local/bin/openrouter-provision (the binary this repo ships at
# scripts/openrouter-provision.py) to mint per-agent child keys.
# Before this step existed, no install path placed the binary on the
# VM — the gateway clone put it at /tmp/openclaw-gateway/... but
# nothing copied it to /usr/local/bin/, so configure-openclaw-agent.sh
# silently fell back to the shared OPENROUTER_API_KEY on every
# deploy (incident: linux-desktop-seed run 27833801264).
#
# This step makes the install explicit and idempotent. It only
# touches the CLI binary; the master provisioning key is a separate
# concern handled by install-openrouter-provisioning.sh (run by hand
# once, when the key is first minted — see
# docs/concepts/per-agent-openrouter-keys.md).
provision_src="$REPO_ROOT/scripts/openrouter-provision.py"
provision_dst="/usr/local/bin/openrouter-provision"
if [[ -f "$provision_src" ]]; then
    if [[ -f "$provision_dst" ]] && cmp -s "$provision_src" "$provision_dst"; then
        log_info "openrouter-provision already installed and up-to-date"
    else
        log_info "Installing openrouter-provision CLI..."
        # `install -m 0755` sets the executable bit and renames
        # atomically — preferred over `cp` + `chmod` per the
        # AGENTS.md deploy-snapshot incident (cp 8.32 fails on
        # 0400 source/dest under some kernels).
        install -m 0755 "$provision_src" "$provision_dst"
        log_info "openrouter-provision CLI installed to $provision_dst"
    fi
else
    log_warn "openrouter-provision source not found at $provision_src"
fi

# 5. Install shared viz service (mermaid/graphviz/chartjs render server)
viz_install_src="$REPO_ROOT/scripts/services/install-viz-service.sh"
if [[ -f "$viz_install_src" ]]; then
    log_info "Installing shared viz service..."
    bash "$viz_install_src"
else
    log_warn "Viz service installer not found at $viz_install_src"
fi

# 6. Install canonical skills to ~/.openclaw/skills/<name>/SKILL.md
#
# Why: skills live in config/skills/ as the source of truth but the gateway
# runtime reads from ~/.openclaw/skills/. Until this step existed, the only
# way to make a new skill visible to a VM was a manual `cp -r`, which meant
# every skill landing on main was invisible to every deployed VM until
# someone remembered to copy it. (Caught 2026-06-19: PRs #25, #26, #27 all
# landed skills on main but the prod VM did not pick them up.)
#
# Behavior:
#   - Iterates config/skills/<name>/ in the repo.
#   - For each <name>, copies <name>/SKILL.md to
#     $HOME/.openclaw/skills/<name>/SKILL.md.
#   - If a nested <name>/<name>/SKILL.md exists, also copies that to
#     $HOME/.openclaw/skills/<name>/<name>/SKILL.md (the historical
#     "full body" companion to the top-level "command manifest" copy).
#   - Idempotent by SHA: skips the copy when source and dest match, so
#     re-running deploy.sh on an unchanged repo is a no-op.
#   - Uses install(1) with mode 0644 (per AGENTS.md deploy-snapshot
#     incident: cp against 0400 files fails on cp 8.32).
#   - Refuses to copy SKILL.md files without a `name:` frontmatter key —
#     those are malformed and we WARN rather than deploy broken skills.
#
# Sandbox-safe: honors $HOME so BATS tests can install into a fake home.
skills_src_root="$REPO_ROOT/config/skills"
skills_dst_root="${HOME:?HOME must be set}/.openclaw/skills"
if [[ -d "$skills_src_root" ]]; then
    log_info "Syncing canonical skills to $skills_dst_root"
    shopt -s nullglob
    installed_count=0
    skipped_count=0
    warned_count=0
    for skill_dir in "$skills_src_root"/*/; do
        skill_name="$(basename "$skill_dir")"
        # Validate skill name (matches openclaw's slug pattern)
        if ! [[ "$skill_name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
            log_warn "Skipping skill with invalid slug: $skill_name"
            warned_count=$((warned_count + 1))
            continue
        fi

        # Sync the canonical SKILL.md
        src_skill="$skill_dir/SKILL.md"
        dst_skill_dir="$skills_dst_root/$skill_name"
        dst_skill="$dst_skill_dir/SKILL.md"
        if [[ -f "$src_skill" ]]; then
            # Reject SKILL.md files missing a name: frontmatter key.
            if ! head -20 "$src_skill" | grep -q '^name:'; then
                log_warn "Skipping $skill_name/SKILL.md: missing 'name:' frontmatter"
                warned_count=$((warned_count + 1))
                continue
            fi
            mkdir -p "$dst_skill_dir"
            if [[ -f "$dst_skill" ]] && \
               cmp -s "$src_skill" "$dst_skill"; then
                skipped_count=$((skipped_count + 1))
            else
                install -m 0644 "$src_skill" "$dst_skill"
                installed_count=$((installed_count + 1))
            fi
        else
            log_warn "No SKILL.md found in $skill_name/ (skipping)"
            warned_count=$((warned_count + 1))
            continue
        fi

        # Sync the nested <name>/<name>/SKILL.md companion if present.
        src_nested="$skill_dir/$skill_name/SKILL.md"
        dst_nested_dir="$dst_skill_dir/$skill_name"
        dst_nested="$dst_nested_dir/SKILL.md"
        if [[ -f "$src_nested" ]]; then
            mkdir -p "$dst_nested_dir"
            if [[ -f "$dst_nested" ]] && \
               cmp -s "$src_nested" "$dst_nested"; then
                skipped_count=$((skipped_count + 1))
            else
                install -m 0644 "$src_nested" "$dst_nested"
                installed_count=$((installed_count + 1))
            fi
        fi
    done
    shopt -u nullglob
    log_info "Skills sync: $installed_count installed, $skipped_count up-to-date, $warned_count warned"
else
    log_warn "Skills source dir not found: $skills_src_root (skipping skill sync)"
fi

log_info "OpenClaw Gateway installation complete"
