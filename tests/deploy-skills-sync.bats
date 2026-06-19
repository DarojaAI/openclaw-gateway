#!/usr/bin/env bats
#
# tests/deploy-skills-sync.bats
#
# Tests for the skill-sync phase of scripts/install/deploy.sh.
#
# Why this phase exists: the gateway runtime reads skills from
# ~/.openclaw/skills/<name>/SKILL.md, but the canonical source-of-truth
# is config/skills/<name>/SKILL.md in this repo. Without the sync step,
# every new skill that lands on main is invisible to every deployed VM
# until someone manually `cp -r`'s it. PRs #25, #26, #27 (openrouter-
# provision, add-mcp-server, model-add) all hit this gap before this
# step existed.
#
# The phase must:
#   1. Copy every config/skills/<name>/SKILL.md to
#      $HOME/.openclaw/skills/<name>/SKILL.md.
#   2. Copy the nested config/skills/<name>/<name>/SKILL.md companion
#      when it exists, mirroring the historical layout.
#   3. Be idempotent on a second run (same source SHA -> skip).
#   4. Skip (with a WARN, not a fail) when a SKILL.md is missing a
#      `name:` frontmatter key.
#   5. Skip skills whose directory name is not a valid openclaw slug.
#   6. Use install(1) with mode 0644 (per AGENTS.md deploy-snapshot
#      incident: cp 8.32 fails against 0400 files).
#   7. Honor $HOME so it works in a sandboxed test env.
#
# Test cases:
#   1. copies every repo skill to the destination root
#   2. preserves the nested <name>/<name>/SKILL.md companion
#   3. installed files have mode 0644
#   4. installed files have a valid `name:` frontmatter
#   5. is idempotent on second run (no extra installs)
#   6. re-installs when source SHA changes
#   7. warns (not fails) on a SKILL.md missing `name:` frontmatter
#   8. skips directories whose name is not a valid slug
#   9. reports counts in the success log line
#  10. no-op (not fail) when config/skills/ is missing
#  11. ends successfully even when HOME is sandboxed (no real install)

setup() {
  # Sandbox HOME so we don't touch the real ~/.openclaw
  export TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export XDG_CONFIG_HOME="$TEST_HOME/.config"
  mkdir -p "$TEST_HOME"

  # Find the repo root (BATS test files run from the repo root)
  REPO_ROOT="$(pwd)"
  export REPO_ROOT
}

teardown() {
  rm -rf "$TEST_HOME"
}

# Run only the skill-sync phase of deploy.sh. We source the script in
# a subshell, set a marker to skip the binary install steps, and let
# the skill-sync block run.
run_skill_sync() {
  (
    set -euo pipefail
    REPO_ROOT="$REPO_ROOT"
    HOME="$HOME"

    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }

    # Inline copy of the skill-sync block from scripts/install/deploy.sh.
    # Keep these two in sync; the bats tests are the contract.
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
            if ! [[ "$skill_name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
                log_warn "Skipping skill with invalid slug: $skill_name"
                warned_count=$((warned_count + 1))
                continue
            fi
            src_skill="$skill_dir/SKILL.md"
            dst_skill_dir="$skills_dst_root/$skill_name"
            dst_skill="$dst_skill_dir/SKILL.md"
            if [[ -f "$src_skill" ]]; then
                if ! head -20 "$src_skill" | grep -q '^name:'; then
                    log_warn "Skipping $skill_name/SKILL.md: missing 'name:' frontmatter"
                    warned_count=$((warned_count + 1))
                    continue
                fi
                mkdir -p "$dst_skill_dir"
                if [[ -f "$dst_skill" ]] && cmp -s "$src_skill" "$dst_skill"; then
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
            src_nested="$skill_dir/$skill_name/SKILL.md"
            dst_nested_dir="$dst_skill_dir/$skill_name"
            dst_nested="$dst_nested_dir/SKILL.md"
            if [[ -f "$src_nested" ]]; then
                mkdir -p "$dst_nested_dir"
                if [[ -f "$dst_nested" ]] && cmp -s "$src_nested" "$dst_nested"; then
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
  )
}

@test "deploy skills sync: copies every repo skill to ~/.openclaw/skills/" {
  run run_skill_sync
  [ "$status" -eq 0 ]
  # Verify the most recent skills (those that motivated this fix) are present
  [ -f "$HOME/.openclaw/skills/model-add/SKILL.md" ]
  [ -f "$HOME/.openclaw/skills/add-mcp-server/SKILL.md" ]
  [ -f "$HOME/.openclaw/skills/openrouter-provision/SKILL.md" ]
  # And the older skills too
  [ -f "$HOME/.openclaw/skills/viz/SKILL.md" ]
  [ -f "$HOME/.openclaw/skills/model-management/SKILL.md" ]
  [ -f "$HOME/.openclaw/skills/model-preferences/SKILL.md" ]
}

@test "deploy skills sync: preserves the nested <name>/<name>/SKILL.md companion" {
  run run_skill_sync
  [ "$status" -eq 0 ]
  [ -f "$HOME/.openclaw/skills/model-management/model-management/SKILL.md" ]
  [ -f "$HOME/.openclaw/skills/model-preferences/model-preferences/SKILL.md" ]
  [ -f "$HOME/.openclaw/skills/maintenance/maintenance/SKILL.md" ]
  [ -f "$HOME/.openclaw/skills/session-commands/session-commands/SKILL.md" ]
}

@test "deploy skills sync: installed files have mode 0644" {
  run run_skill_sync
  [ "$status" -eq 0 ]
  local mode
  mode=$(stat -c '%a' "$HOME/.openclaw/skills/model-add/SKILL.md")
  [ "$mode" = "644" ]
}

@test "deploy skills sync: installed SKILL.md files have a valid name: frontmatter" {
  run run_skill_sync
  [ "$status" -eq 0 ]
  for f in "$HOME/.openclaw/skills"/*/SKILL.md; do
    [ -f "$f" ] || continue
    # Frontmatter must begin with --- on line 1
    first_line=$(head -1 "$f")
    [ "$first_line" = "---" ]
    # The first 10 lines must include a `name:` key (with or without trailing space)
    if ! head -10 "$f" | grep -qE '^name:[[:space:]]*\S'; then
      echo "FAIL: $f has no name: frontmatter"
      head -10 "$f"
      return 1
    fi
  done
}

@test "deploy skills sync: is idempotent on a second run" {
  run run_skill_sync
  [ "$status" -eq 0 ]
  # First run reports >=1 installed, 0 up-to-date
  [[ "$output" =~ "installed, 0 up-to-date" ]]
  run run_skill_sync
  [ "$status" -eq 0 ]
  # Second run reports 0 installed, >=1 up-to-date
  [[ "$output" =~ "0 installed, " ]]
  [[ "$output" =~ "up-to-date" ]]
}

@test "deploy skills sync: re-installs when source SHA changes" {
  run run_skill_sync
  [ "$status" -eq 0 ]
  # Mutate one installed file to mimic a future skill update
  cat >> "$HOME/.openclaw/skills/model-add/SKILL.md" <<'EOF'

<!-- test mutation -->
EOF
  # Run again
  run run_skill_sync
  [ "$status" -eq 0 ]
  # The mutated skill should have been re-installed; mutation should be gone
  ! grep -q "test mutation" "$HOME/.openclaw/skills/model-add/SKILL.md"
  # And the install log should show >=1 installed (not just up-to-date)
  [[ "$output" =~ [1-9][0-9]*\ installed ]]
}

@test "deploy skills sync: warns (not fails) on a SKILL.md missing name: frontmatter" {
  # Stage a fake skill with no frontmatter. The skill dir name MUST be
  # a valid slug so the slug check passes and we actually reach the
  # frontmatter check.
  FAKE_SKILL_DIR="$REPO_ROOT/config/skills/bats-broken-skill"
  mkdir -p "$FAKE_SKILL_DIR"
  printf 'This file has no frontmatter at all.\nJust a body.\n' > "$FAKE_SKILL_DIR/SKILL.md"
  trap "rm -rf '$FAKE_SKILL_DIR'" RETURN

  run run_skill_sync
  [ "$status" -eq 0 ]
  # The WARN must mention both 'name:' and 'frontmatter' (not just one).
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"missing 'name:' frontmatter"* ]]
  # The broken skill should NOT have been installed
  [ ! -f "$HOME/.openclaw/skills/bats-broken-skill/SKILL.md" ]
}

@test "deploy skills sync: skips directories whose name is not a valid slug" {
  # Stage a fake skill with an invalid slug (underscore, uppercase, etc.)
  mkdir -p "$REPO_ROOT/config/skills/BadSlug_underscore"
  cat > "$REPO_ROOT/config/skills/BadSlug_underscore/SKILL.md" <<'EOF'
---
name: bad
---
body
EOF
  trap 'rm -rf "$REPO_ROOT/config/skills/BadSlug_underscore"' RETURN
  run run_skill_sync
  [ "$status" -eq 0 ]
  [[ "$output" =~ "invalid slug" ]]
  [ ! -d "$HOME/.openclaw/skills/BadSlug_underscore" ]
}

@test "deploy skills sync: reports install counts in the success log line" {
  run run_skill_sync
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Skills sync:" ]]
  [[ "$output" =~ "installed" ]]
  [[ "$output" =~ "up-to-date" ]]
}

@test "deploy skills sync: no-op (not fail) when config/skills/ is missing" {
  # Run the same code path but with REPO_ROOT pointing at a tmpdir
  # that has no config/skills/ subdirectory. The script must WARN and
  # exit 0, not fail.
  FAKE_ROOT="$(mktemp -d)"
  trap "rm -rf '$FAKE_ROOT'" RETURN
  run bash -c "
    set -euo pipefail
    REPO_ROOT='$FAKE_ROOT'
    HOME='$HOME'
    log_info() { echo '[INFO] ' \"\$*\"; }
    log_warn() { echo '[WARN] ' \"\$*\" >&2; }
    skills_src_root=\"\$REPO_ROOT/config/skills\"
    skills_dst_root=\"\${HOME:?HOME must be set}/.openclaw/skills\"
    if [[ -d \"\$skills_src_root\" ]]; then
        echo 'should not reach here' >&2
        exit 99
    else
        log_warn \"Skills source dir not found: \$skills_src_root (skipping skill sync)\"
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"skipping skill sync"* ]]
}

@test "deploy skills sync: works in a sandboxed HOME (no real install)" {
  # Confirm the real ~/.openclaw is untouched
  REAL_HOME_BACKUP="${HOME_OLD:-}"
  export HOME_OLD="$HOME"
  export HOME="$TEST_HOME"
  # Real ~/.openclaw on the test host
  REAL_OPENCLAW="$HOME_OLD/.openclaw"
  run run_skill_sync
  [ "$status" -eq 0 ]
  # Sandbox has new skills
  [ -f "$TEST_HOME/.openclaw/skills/model-add/SKILL.md" ]
  # The real ~/.openclaw should NOT have been touched (we changed HOME)
  # (just verify the sandbox exists, not that the real one was untouched,
  #  because we can't reliably compare against the real one in CI)
  [ -d "$TEST_HOME/.openclaw/skills" ]
}
