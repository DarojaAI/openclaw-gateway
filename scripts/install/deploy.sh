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

# 7. Install lane-health watchdog (user systemd timer).
#
# Why: upstream openclaw@2026.6.8 does not preempt wedged model_call
# lanes. The watchdog scans the journal every 30s and kills lanes that
# exceed the wall-clock budget. See
# docs/incidents/2026-06-28-multi-session-gateway-starvation.md in
# DarojaAI/linux-desktop-seed.
#
# Behavior:
#   - Honors $HOME for sandbox tests.
#   - Skipped if --no-lane-health-probe arg was passed to deploy.sh.
#   - Operator-channel is read from $OPENCLAW_OPERATOR_CHANNEL if set.
lane_health_installer="$REPO_ROOT/scripts/install/install-lane-health-probe.sh"
if [[ -f "$lane_health_installer" ]] && [[ "${SKIP_LANE_HEALTH_PROBE:-0}" != "1" ]]; then
    install_args=()
    if [[ -n "${OPENCLAW_OPERATOR_CHANNEL:-}" ]]; then
        install_args+=(--operator-channel "$OPENCLAW_OPERATOR_CHANNEL")
    fi
    if bash "$lane_health_installer" "${install_args[@]}"; then
        log_info "Lane-health probe installed"
    else
        log_warn "Lane-health probe install failed (non-fatal; deploy continues)"
    fi
else
    log_warn "Lane-health probe installer not found or skipped"
fi

# 8. Post-deploy lane-health verification.
#
# Why: refuse to declare a deploy healthy if any lane is currently
# wedged. The L3 deploy pipeline invokes this script; failing the gate
# forces the operator to restart cleanly.
#
# Behavior:
#   - Reads gateway user journal for last 60s.
#   - Exits non-zero if any `long-running session` event has age > budget
#     and recovery=none.
#   - Skipped if --skip-lane-health-check or $SKIP_POST_DEPLOY_LANE_CHECK=1.
if [[ "${SKIP_POST_DEPLOY_LANE_CHECK:-0}" != "1" ]]; then
    lane_check="$REPO_ROOT/scripts/post-deploy-verify-lane-health.sh"
    if [[ -f "$lane_check" ]]; then
        if bash "$lane_check"; then
            log_info "Post-deploy lane-health check passed"
        else
            rc=$?
            log_error "Post-deploy lane-health check FAILED (rc=$rc)"
            log_error "Refusing to declare deploy healthy. Remediate, then re-run."
            exit "$rc"
        fi
    else
        log_warn "Post-deploy lane-health check not found at $lane_check"
    fi
else
    log_warn "Post-deploy lane-health check skipped (SKIP_POST_DEPLOY_LANE_CHECK=1)"
fi

# 9. Post-deploy memory-index verification.
#
# Why: a freshly-deployed gateway can be "up" while the memory index
# is broken (DarojaAI/openclaw-gateway#21). The upstream OpenClaw
# runtime does not detect a missing or mismatched indexIdentity at
# boot — the disable message only surfaces when an agent calls
# memory_search. Failing the deploy gate forces the operator to
# rebuild the index (`openclaw memory index --force`) before the
# deploy is considered healthy.
#
# Upstream openclaw/openclaw owns the underlying race fix
# (PR #90453); this script is the L3b-side detection and
# deploy-gate integration. Upstream fix is the durable resolution;
# this gate catches future regressions of the same shape.
#
# Behavior:
#   - Reads `openclaw memory status --json` and inspects per-agent
#     indexIdentity.
#   - Exit 0 → OK, log and continue.
#   - Exit 1 → degraded index on an agent that has data; FAIL the
#     deploy gate (log_error + exit 1).
#   - Exit 2 → probe failure (openclaw not on PATH, JSON parse error).
#     Log a warning and continue — we don't want a missing CLI to
#     block deploys.
#   - Skipped when SKIP_POST_DEPLOY_MEMORY_CHECK=1.
#   - Skipped when the verify script is not present (still
#     soft-warns so the operator knows the gate is not running).
memory_check="$REPO_ROOT/scripts/post-deploy-verify-memory-index.sh"
if [[ "${SKIP_POST_DEPLOY_MEMORY_CHECK:-0}" == "1" ]]; then
    log_warn "Post-deploy memory-index check skipped (SKIP_POST_DEPLOY_MEMORY_CHECK=1)"
elif [[ -f "$memory_check" ]]; then
    # Capture rc explicitly; do not let `set -e` abort on exit 1 (the
    # script's documented "deploy gate fails" exit code).
    set +e
    "$memory_check"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        log_info "Post-deploy memory-index check passed"
    elif [[ $rc -eq 1 ]]; then
        log_error "Post-deploy memory-index check FAILED (rc=$rc) — deploy gate refuses to declare this deploy healthy."
        log_error "Remediation: openclaw memory index --force (or /memory-rebuild from Discord), then re-run the deploy."
        exit 1
    else
        log_warn "Post-deploy memory-index check exited $rc (probe failure) — continuing deploy"
    fi
else
    log_warn "Post-deploy memory-index check not found at $memory_check"
fi

log_info "OpenClaw Gateway installation complete"
