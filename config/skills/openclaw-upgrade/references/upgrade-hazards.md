# OpenClaw Upgrade Hazards

This file lists, per source→target version pair, the storage, config-schema, and SDK migrations the `openclaw-upgrade` skill enforces. The skill refuses to proceed if the requested source→target pair is not present here.

**When you add a new pair, verify the entry against the target's release notes before committing it.** The skill trusts this file as the source of truth for what is required; if the file is wrong, the upgrade is wrong.

## Format

Each pair is a `##` section. Within each, three subsections are required:

- **Pre-upgrade** — steps that must complete *before* the deploy runs. Typically: backup, archive, snapshot.
- **Post-upgrade** — steps that must complete *after* the deploy and on-VM verification. Typically: Doctor migration, schema verification, restart.
- **Rollback** — the path back if the upgrade fails. State explicitly when rollback is one-way or data-lossy.

The skill matches source→target by major.minor (`x.y.x`). Patch differences within the same minor are the same upgrade.

---

## 2026.6.x → 2026.7.x

### Pre-upgrade
- Run `openclaw backup create` to capture the verified backup of sessions, transcripts, and config.
- Snapshot `config/openclaw-defaults.json` and `config/openclaw-test-vm.json` from the gateway repo. The Doctor will rewrite the `channels.discord.streaming` block to the new nested format; diff against the snapshot to confirm the migration is correct.

### Post-upgrade
- Run `openclaw doctor --migrate`. The Doctor handles the channel-streaming nested-format migration (six channel keys including Discord moved to nested format; legacy scalar keys removed; upstream PRs #105709, #113533, #104693). Assert exit 0.
- Diff the post-upgrade `config/openclaw-defaults.json` against the pre-upgrade snapshot. Confirm `channels.discord.streaming` landed in the new nested format. Legacy alias keys (e.g., `channels.discord.streamingMode`) MUST NOT be present.
- Restart the gateway service. Confirm it answers the version endpoint and reports the new version.

### Rollback
- Restore the verified backup. The pre-7.x storage format is unchanged from 6.x, so rollback is data-loss-free.
- Restore the pre-upgrade config snapshot if Doctor migration produced unwanted changes.
- The npm install can be re-pinned to the source version without a separate migration step; just bump `config/openclaw-version` back.

---

## 2026.7.x → 2026.8.x

### Pre-upgrade
- **Mandatory.** Run `openclaw backup sqlite create`. This is the new compact SQLite snapshot CLI added in 8.x (upstream PR #94805). Required because the install performs a one-way migration to SQLite for sessions and transcripts.
- Run `openclaw backup create` for the legacy file-based artifacts as well. Some agents may still have non-transcript file artifacts.
- Archive legacy transcripts via the CLI's transcript-archive command so a future rollback can restore them. Per upstream release notes: *"Before downgrading to an older file-backed release, use the current CLI to restore archived legacy transcript artifacts; sessions created after the migration will not appear in older releases."*

### Post-upgrade
- Confirm SQLite storage is active: `openclaw doctor` reports `state-storage: sqlite (schema v6)` (or the schema version present in the installed binary's `package.json`).
- Run `openclaw backup sqlite verify` against the pre-upgrade snapshot to confirm it can still be restored.
- Run `openclaw backup sqlite list` and confirm the post-upgrade snapshot is present.
- Confirm the Discord channel `streaming` block is still in the new nested format (no regression from the 7.x migration).
- Restart the gateway service. Confirm it answers the version endpoint and reports version `2026.8.1`.

### Rollback
- **One-way door for sessions.** Rollback to pre-8.x is lossy for sessions created after the migration.
- Path: stop the gateway, run the CLI's transcript-restore command against the legacy archive captured pre-upgrade, downgrade the binary, restart. Sessions created between the migration and the rollback are not recoverable from the SQLite store in pre-8.x.
- Plan a forward-only upgrade strategy. Avoid rollback if possible; treat rollback as an incident-response path, not a routine operation.

---

## How to add a new pair

1. Read the target version's release notes at `https://docs.openclaw.ai/releases/<version>`.
2. Identify every storage migration, config-schema migration, plugin-SDK break, and Node-runtime floor change.
3. Write the entry with Pre-upgrade, Post-upgrade, and Rollback subsections.
4. For one-way migrations (storage format change), state it explicitly in Rollback.
5. Commit the change to `DarojaAI/openclaw-gateway` so it ships with the next deploy.
6. The `openclaw-upgrade` skill will pick it up automatically on the next invocation.
