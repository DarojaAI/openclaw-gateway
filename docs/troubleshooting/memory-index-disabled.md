# Memory Index Disabled — Recovery and Prevention

**Symptom:** `memory_search` returns

```json
{
  "results": [],
  "disabled": true,
  "unavailable": true,
  "error": "index metadata is missing",
  "warning": "Tell the user: memory search is paused because the memory index was built with a different embedding provider/model/settings."
}
```

`memory_search` is hard-disabled in this state — the tool cannot fall back to keyword/BM25 search and returns empty results to every caller.

## Diagnose

```bash
# Per-agent status, machine-readable
openclaw memory status --json | jq '.[].status.custom.indexIdentity'

# Human-readable, one agent
openclaw memory status --agent <agentId>
```

The relevant fields are:
- `status.custom.indexIdentity.status` — `ok`, `missing`, `mismatch`, or unknown
- `status.custom.indexIdentity.reason` — free-form failure reason
- `status.provider` vs `status.requestedProvider` — model swap detection
- `status.chunks` and `status.files` — does any data exist?

The L3b deploy gate (`scripts/post-deploy-verify-memory-index.sh`) classifies the
state into one of:
- `ok` — index is healthy
- `warn-fresh` — index missing but no data has been indexed yet (first-use will rebuild)
- `warn-swap` — `provider` ≠ `requestedProvider` (a model swap happened under the index)
- `warn-unknown` — unrecognized identity state (forward-compat)
- `fail` — `missing` or `mismatch` AND the agent has data — deploy gate fails

## Recover

The recovery path is documented in `openclaw memory status` output:

```bash
# Rebuild the index end-to-end with the current embedding provider/model.
openclaw memory index --force

# Verify metadata is present.
openclaw memory status --json

# Smoke test recall with a known query.
openclaw memory search "some known query" --max-results 5
```

Or from Discord, the L3b skill (when installed) provides the same:

```
/memory-rebuild
```

## Why this happens

Three known upstream causes:

1. **Provider/model change.** A model swap in the gateway config (or upstream OpenRouter routing) caused the active embedding model to differ from the one used to build the index. The indexer's identity check fails closed.
2. **Index metadata lost.** The on-disk index exists but the `.meta` sidecar is missing or was written by a different indexer version. Causes: incomplete `openclaw memory index` run, manual cleanup, or storage drop-in that strips dotfiles.
3. **Storage path change.** The configured memory storage path now points to a different volume where the previous index is not present, so the loader sees an empty index directory and produces the "metadata is missing" diagnostic.

The root-cause upstream race is tracked in:

- [`openclaw/openclaw#90361`](https://github.com/openclaw/openclaw/issues/90361) — root-cause race
- [`openclaw/openclaw#90453`](https://github.com/openclaw/openclaw/pull/90453) — mergeable closing PR

PR #90453 lands a manager-level reindex latch and stable status snapshots; it
is owned by upstream maintainers and L3b does not duplicate the fix.

## What L3b does to prevent recurrence

The L3b deploy gate (`scripts/post-deploy-verify-memory-index.sh`, wired into
`scripts/install/deploy.sh` as the final step) catches regressions at the
deploy boundary:

| Live state                                 | Old behavior          | New behavior                                |
| ------------------------------------------ | --------------------- | ------------------------------------------- |
| `identity=ok`                              | pass                  | pass                                        |
| `identity=missing` AND no data              | pass (silent)         | pass + WARN (first-use will rebuild)        |
| `identity=missing` AND has data            | pass (silent)         | **FAIL deploy gate**                        |
| `identity=mismatch` AND has data           | pass (silent)         | **FAIL deploy gate**                        |
| `provider` ≠ `requestedProvider`           | pass (silent)         | pass + WARN (model-swap signal)             |
| `openclaw memory status --json` errors     | undefined             | WARN (probe failure, do not block deploy)   |
| `openclaw` not on PATH                     | crash                 | exit 2, soft-warn                           |

The gate is opt-out via `SKIP_POST_DEPLOY_MEMORY_CHECK=1` (for offline / debug
deploys). The fresh-install WARN can be promoted to FAIL via
`MEMORY_CHECK_FAIL_ON_FRESH=1` for prod environments where the index should
always be built.

## Forward-compat behavior

The parser (`scripts/lib-parse-memory-status.py`) treats unknown identity
states as `warn-unknown` (not FAIL), so future upstream identity values that
we don't yet recognize do not break the deploy. Operators see the WARN line
in deploy output and can decide whether to rebuild.

## Related

- [`DarojaAI/openclaw-gateway#21`](https://github.com/DarojaAI/openclaw-gateway/issues/21) — original issue
- [`DarojaAI/linux-desktop-seed/docs/incidents/2026-06-24-override-conf-malformed-heredoc.md`](https://github.com/DarojaAI/linux-desktop-seed/blob/main/docs/incidents/2026-06-24-override-conf-malformed-heredoc.md) — pattern: prefer validated structural writes over silent-recovery
- `scripts/post-deploy-verify-memory-index.sh` — implementation
- `scripts/lib-parse-memory-status.py` — pure decision logic
- `tests/post-deploy-verify-memory-index.bats` — 19 cases
