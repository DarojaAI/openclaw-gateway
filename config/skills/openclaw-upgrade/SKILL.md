---
name: openclaw-upgrade
description: Upgrade OpenClaw gateway binary to a target version. Bumps config/openclaw-version, deploys, verifies against the on-VM package.json. Refuses no-op installs.
trigger: "/openclaw-upgrade"
---

# OpenClaw Upgrade

The OpenClaw binary lives at `/usr/lib/node_modules/openclaw/` on the gateway VM. The deploy source of truth is `config/openclaw-version` in the gateway repo (`DarojaAI/openclaw-gateway`, on disk at `/tmp/openclaw-gateway/`). The runtime pin at `/tmp/openclaw-pinned-version` is downstream of that source. This skill enforces a strict order: read hazards → bump source of truth → trigger deploy → verify on-VM binary → run hazards' post-upgrade gates.

This skill is **parametrically version-aware**. The procedural shell never changes. The storage, config-schema, and SDK migrations each upgrade requires live in `config/skills/openclaw-upgrade/references/upgrade-hazards.md`. The skill refuses to proceed if the requested source→target pair is not present there. The skill does NOT hard-code "run sqlite backup" or "migrate nested streaming" — it reads those from the hazards file at runtime.

## When to use

- The user asks to upgrade OpenClaw to a specific version (e.g., "upgrade to 2026.8.1").
- The gateway repo checkout exists at `/tmp/openclaw-gateway/`.
- The target version is published on the public npm registry (verify with `npm view openclaw@<target> version`).

## Inputs

- `TARGET` (required): the version to upgrade to, e.g., `2026.8.1`. If the user says "latest", resolve via `npm view openclaw dist-tags.latest`.
- `SSH_USER`, `SSH_HOST` (required for verification): SSH access to the gateway VM.
- `GATEWAY_REPO_DIR` (default `/tmp/openclaw-gateway`): path to the gateway repo checkout.

## Environment

The skill needs:
- `ssh` to the gateway VM (`SSH_USER@SSH_HOST` must be reachable with key auth).
- `python3` on the gateway VM (for `package.json` parsing).
- `npm` locally (to resolve `latest` if the user did not specify a version).
- `git` locally with push access to `DarojaAI/openclaw-gateway`.

## Anti-patterns (read before doing anything)

- **NEVER** report "upgrade complete" from a deploy log line. The only valid post-condition is the on-VM binary's `package.json` `version` field.
- **NEVER** treat a no-op install (e.g., "OpenClaw binary already installed") as success. That line proves only that the deploy ran, not that an upgrade occurred.
- **NEVER** trust `/tmp/openclaw-pinned-version` matching the target as evidence. That file is downstream of the source of truth.
- **NEVER** run `openclaw-version-check.sh` with `config/openclaw-version`'s content as `$1`. Pass `TARGET`. The script's own comments document why inline `$VAR` substitution breaks under secret-masker expansion.
- **NEVER** skip pre-upgrade steps listed in the hazards entry, even if the operator insists. If the entry lists a storage-migration backup, the upgrade is not safe to perform without it.
- **NEVER** invent hazards. If the source→target pair is missing from the hazards file, STOP. Add the entry first, with verification against the target's actual release notes. Do not proceed on assumption.

## Steps

### 1. Identify installed and target

```bash
GATEWAY_REPO_DIR="${GATEWAY_REPO_DIR:-/tmp/openclaw-gateway}"
SOURCE_PIN="$(tr -d '[:space:]' < "$GATEWAY_REPO_DIR/config/openclaw-version")"
RUNTIME_PIN="$(tr -d '[:space:]' < /tmp/openclaw-pinned-version)"
TARGET="${TARGET:-$(npm view openclaw dist-tags.latest)}"

# On-VM installed version — the only ground truth.
INSTALLED="$(ssh "${SSH_USER}@${SSH_HOST}" \
  "python3 -c 'import json;print(json.load(open(\"/usr/lib/node_modules/openclaw/package.json\"))[\"version\"])'" 2>/dev/null || echo "unknown")"
```

If `INSTALLED == TARGET`: STOP. Report a no-op upgrade to the user; do not perform any write.

If `SOURCE_PIN != INSTALLED`: WARN loudly. The deploy source of truth disagrees with the on-VM binary. This is the drift that bit the prior two attempts. Investigate before proceeding.

If `RUNTIME_PIN != TARGET`: WARN. The drift watchdog will fire. Plan to update it after the upgrade.

### 2. Look up the source→target pair in the hazards file

```bash
HAZARDS="$GATEWAY_REPO_DIR/config/skills/openclaw-upgrade/references/upgrade-hazards.md"
if [ ! -f "$HAZARDS" ]; then
  echo "FATAL: $HAZARDS does not exist." >&2
  exit 1
fi

# Match by major.minor. Patch-level differences inside the same minor are the same upgrade.
SOURCE_MM="$(echo "$INSTALLED" | grep -oE '^[0-9]+\.[0-9]+')"
TARGET_MM="$(echo "$TARGET"   | grep -oE '^[0-9]+\.[0-9]+')"

if ! grep -qE "^## ${SOURCE_MM}\.x → ${TARGET_MM}\.x" "$HAZARDS"; then
  echo "FATAL: no hazards entry for $INSTALLED → $TARGET." >&2
  echo "Add a section to $HAZARDS with Pre-upgrade, Post-upgrade, and Rollback subsections before retrying." >&2
  exit 1
fi
```

The matched section MUST contain three subsections: Pre-upgrade, Post-upgrade, Rollback. If any is missing, STOP and refuse to proceed.

### 3. Execute the Pre-upgrade subsection

Extract the Pre-upgrade block from the matched section. Execute every step in order. **Do not proceed if any step exits non-zero.**

This is where storage-migration backups live, when applicable. The skill does not hard-code "sqlite backup" — it reads whatever the hazards entry says.

### 4. Bump the source of truth

This step MUST happen before the deploy. The deploy reads `config/openclaw-version`; if it disagrees with the bump, the deploy is a no-op.

```bash
echo "$TARGET" > "$GATEWAY_REPO_DIR/config/openclaw-version"
echo "$TARGET" > /tmp/openclaw-pinned-version
cd "$GATEWAY_REPO_DIR"
git add config/openclaw-version
git -c user.email='openclaw-upgrade@daroja.ai' \
    -c user.name='openclaw-upgrade skill' \
    commit -m "chore(openclaw): pin to $TARGET"
git push origin main
```

`config/openclaw-version` is the load-bearing edit. `openclaw-pinned-version` is downstream and must match — otherwise the drift watchdog will fire post-upgrade.

### 5. Trigger the deploy

The skill does not choose the deploy mechanism. Confirm the bump is in place and let the operator trigger. Suggested forms (operator chooses):

- GitHub Actions: `gh workflow run deploy.yml --repo DarojaAI/openclaw-gateway --ref main -f environment=production`
- Layer 3a (linux-desktop-seed) workflow, if that is the path in this environment.
- Manual SSH invocation of `bash /opt/openclaw-gateway/scripts/install/deploy.sh`.

**Capture the deploy run URL or exit code. Do not declare the upgrade successful from this.**

### 6. Wait for deploy completion and capture output

Monitor the workflow run or the manual deploy log. Note whether the deploy's install step printed "OpenClaw binary already installed" (no-op marker) or actually ran `npm install -g openclaw@$TARGET`.

A "no-op" deploy log line is a red flag, not a success.

### 7. Verify on-VM (the only valid post-condition)

```bash
INSTALLED_NOW="$(ssh "${SSH_USER}@${SSH_HOST}" \
  "python3 -c 'import json;print(json.load(open(\"/usr/lib/node_modules/openclaw/package.json\"))[\"version\"])'")"
```

`INSTALLED_NOW` MUST equal `TARGET`. If it does not, the upgrade has not happened. **Do not declare success.** Report the discrepancy: expected `TARGET`, actual `INSTALLED_NOW`, deploy log line, hazards entry, and the operator's next decision.

### 8. Execute the Post-upgrade subsection

Extract the Post-upgrade block from the matched hazards section. Execute every step in order. These typically include: Doctor migration assertions, schema verification, restart-and-respond checks, backup verification. **Do not proceed if any step exits non-zero.**

### 9. Confirm the drift watchdog is quiet

```bash
ssh "${SSH_USER}@${SSH_HOST}" \
  "python3 -c 'import json;a=json.load(open(\"/usr/lib/node_modules/openclaw/package.json\"))[\"version\"];b=open(\"/tmp/openclaw-pinned-version\").read().strip();print(\"OK\" if a==b else f\"MISMATCH installed={a} pinned={b}\")'"
```

If the watchdog reports MISMATCH, fix it (write `TARGET` to `/tmp/openclaw-pinned-version`) and re-check.

### 10. Final report

Only after steps 1–9 have all passed, report:

```
OpenClaw upgrade to $TARGET completed.
- Source-of-truth pin:  $GATEWAY_REPO_DIR/config/openclaw-version = $TARGET
- Runtime pin:          /tmp/openclaw-pinned-version = $TARGET
- On-VM binary:         /usr/lib/node_modules/openclaw/package.json version = $TARGET
- Drift watchdog:       quiet (installed == pinned)
- Hazards entry:        $INSTALLED → $TARGET, all Pre-upgrade + Post-upgrade + Rollback steps executed
```

If any step failed, report the failing step and the actual state. Do not claim success.

## Notes

- **Why this skill is parametric, not version-agnostic.** The shell is version-agnostic: same four guards, same step order, same verification. The migration knowledge is version-aware and lives in the hazards file at `config/skills/openclaw-upgrade/references/upgrade-hazards.md`. Hard-coding "run sqlite backup" into the skill would make it wrong for every minor bump that does not include a storage migration. Pretending the upgrade path is the same for all major bumps is what bit the prior two attempts.
- **Why the hazards file lives in the skill's `references/` directory.** It ships with the skill via the standard skill-sync phase of `scripts/install/deploy.sh`. Operators editing the skill are the same operators who edit the hazards file. Co-location is intentional.
- **Why the skill refuses on missing pair.** If a new source→target pair is missing from the hazards file, proceeding means guessing at migrations. The skill's job is to enforce that someone verified the migrations against the target's release notes first.
- **Why `python3 -c` for verification.** The on-VM version read is a one-liner. `openclaw-version-check.sh` is the right tool for re-use, but it requires the secret-masker workaround documented in its own header. Inline `python3 -c` avoids both the masker and the heredoc-parser footgun.
- **On-VM runtime path.** When the skill is invoked on the gateway VM itself (rather than from a dev machine SSHing in), the skill directory lives at `~/.openclaw/skills/openclaw-upgrade/` and the hazards file at `~/.openclaw/skills/openclaw-upgrade/references/upgrade-hazards.md`. The skill reads from `GATEWAY_REPO_DIR` (the gateway repo checkout) as the source of truth; the deployed `~/.openclaw/` copy is for runtime access only.
