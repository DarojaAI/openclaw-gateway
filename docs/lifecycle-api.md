# Lifecycle API

**Endpoint:** `GET /lifecycle`  
**Purpose:** Surface agent lifecycle data for the daroja-intelligence-console.

Refs: [`DarojaAI/openclaw-gateway#108`](https://github.com/DarojaAI/openclaw-gateway/issues/108)

## Response Shape

```json
{
  "sessions": [
    {
      "agent_id": "daroja_coding_agent",
      "session_file": "abc123.trajectory.jsonl",
      "last_event_at": "2026-09-14T15:00:00+00:00",
      "event_count": 42,
      "models_used": ["openrouter/xiaomi/mimo-v2.5"]
    }
  ],
  "crons": [],
  "lessons": [],
  "captured_at": "2026-09-14T16:00:00+00:00"
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `sessions` | array | One entry per trajectory file. Sorted most-recent first. |
| `sessions[].agent_id` | string | Agent that owns the session (directory name under `~/.openclaw/agents/`). |
| `sessions[].session_file` | string | Basename of the `.trajectory.jsonl` file. |
| `sessions[].last_event_at` | string\|null | ISO 8601 timestamp of the most recent event, or null if empty. |
| `sessions[].event_count` | int | Total events in the trajectory file. |
| `sessions[].models_used` | string[] | Deduplicated model IDs seen in the session. |
| `crons` | array | **Stub.** Cron data not yet available from this repo. Returns `[]`. |
| `lessons` | array | **Stub.** Lesson data not yet tracked. Returns `[]`. |
| `captured_at` | string | ISO 8601 timestamp of when this report was generated. |

## Health Check

`GET /healthz` returns `{"status": "ok"}`.

## Running

```bash
# One-shot (print report to stdout)
python3 scripts/lifecycle.py --once

# As a server
python3 scripts/lifecycle.py --port 8099 --host 127.0.0.1
```

No external dependencies — uses Python stdlib only.

## Data Sources

| Field | Source | Status |
|-------|--------|--------|
| `sessions` | `~/.openclaw/agents/*/sessions/*.trajectory.jsonl` | ✅ Implemented |
| `crons` | OpenClaw cron config (gateway runtime) | 🔲 Stub — needs gateway runtime access |
| `lessons` | Not yet tracked | 🔲 Stub — no data source identified |

## Integration with Console

The daroja-intelligence-console proxies `/api/lifecycle` to `LIFECYCLE_URL`.
Set `LIFECYCLE_URL=http://127.0.0.1:8099` (or wherever this server runs)
to connectthe console's Lifecycle view to this endpoint.

## Housekeeping: plugin-captures retention

`~/.openclaw/tmp/plugin-captures/` grows unbounded (~1.8 GiB/day observed;
[issue #134](https://github.com/DarojaAI/openclaw-gateway/issues/134)). The
bounded-retention pruner `scripts/lib-prune-retention.py` keeps that dir (or
any target dir) under two knobs — `--max-age-days` (default 14 days) and
`--max-bytes` (default 20 GiB; K/M/G/T suffixes ok; 0 = no cap) —
deleting oldest-first when either is exceeded. Dry-run is the default; real
deletion requires `--delete`. CLI flags override the `PRUNE_DIR`,
`PRUNE_MAX_AGE_DAYS`, `PRUNE_MAX_BYTES` env vars (the timer's knobs live in
`~/.openclaw/plugin-captures-retention.env`).

### Capture-tree safety ([#141](https://github.com/DarojaAI/openclaw-gateway/issues/141))

The upstream runtime stages one capture tree per plugin-admission event under
`<stateDir>/tmp/plugin-captures/<instanceId>/` — package copies in a
`captures/` child, with an `owner.sqlite` custody/lease token at the instance
root. Plugin load admission compares hashes against the bytes captured at
admission time, so deleting **any** file out of a still-referenced capture
tree (including companion files such as `README.md` / `LICENSE.md`) breaks
the next plugin load. The pruner therefore never deletes inside a
still-referenced capture tree:

- Capture-instance directories are treated as **atomic units** — a tree is
  either kept whole or pruned whole, never file-by-file.
- A tree carrying a **live lease** (`owner.sqlite` or its
  `-journal`/`-wal`/`-shm` sidecars, symlinked or unreadable tokens
  included) is **referenced** → skipped with a warning.
- A **token-less** tree is still referenced while the installed-plugin
  registry (the runtime's `installed_plugin_index` in
  `<stateDir>/state/openclaw-state.sqlite`, falling back to legacy
  `<stateDir>/plugins/installs.json`) is non-empty — skipping with a warning
  — or when the registry cannot be read (fail-loud; never delete anything we
  cannot prove unreferenced).
- Only a token-less tree with a registry proving **zero installed plugins**
  may be pruned, and then only as a whole tree.
- The reference check runs again immediately before each delete, so a tree
  claimed by the runtime between planning and deletion is left alone.

Every skipped tree is reported on its own line
(`skipped (referenced capture): <dir> (<reason>)`) and counted in the
summary as retained bytes — both in dry-run and delete mode. Deploy-step and
timer invocations pass `--capture-aware`; protection also enables itself
automatically whenever the target dir contains capture instances, so older
timer installs are safe without reinstall. `--no-capture-aware` restores the
old generic behavior explicitly.

### Repairing a prune-damaged capture (official path)

If a capture tree was damaged (or files were hand-restored), restoring the
bytes is not enough — admission compares hashes of the bytes at capture time.
The sanctioned repair is to **re-capture the plugin trees**:

```bash
openclaw doctor          # the doctor plugin phase re-captures plugin trees
```

`openclaw plugins registry --refresh` refreshes registry metadata only and
does **not** re-capture plugin trees; it cannot repair a pruned capture.
After `openclaw doctor` completes, restart the gateway so admission sees the
fresh captures.

**Concurrent pruners:** the pruner takes an exclusive `flock` on
`<target>/.prune-retention.lock` for its whole scan+delete cycle.
`linux-desktop-seed`'s (unmerged) `prune-openclaw-staging.sh` targets the same
`tmp/plugin-captures` dir — if it lands, prefer one owner per directory; the
lock only prevents interleaving mid-cycle, it does not reconcile different
retention policies.

Manual purge policy (run by hand when the dir is overflowing):

```bash
# Preview what the policy would delete (capture-aware)
python3 scripts/lib-prune-retention.py --dir ~/.openclaw/tmp/plugin-captures

# Apply the same policy
python3 scripts/lib-prune-retention.py --dir ~/.openclaw/tmp/plugin-captures --delete
```

`scripts/install/deploy.sh` can run the pruner as an optional housekeeping
step: set `OPENCLAW_PLUGIN_CAPTURES_RETENTION=1` to enable it (still
dry-run by default) and additionally `OPENCLAW_PLUGIN_CAPTURES_RETENTION_DELETE=1`
to let it actually delete. Never point it at the live prod plugin-captures
dir from a scratch checkout; run it on the VM whose data it should prune.
