---
name: memory-rebuild
description: Force a full rebuild of the memory index with the active embedding provider/model. Use when the user sends /memory-rebuild, memory_search returns 'index metadata is missing', the status shows identity=missing or mismatch on an agent that has data, or after a model swap in the gateway config. This is the documented recovery path for DarojaAI/openclaw-gateway#21.
commands:
  - name: memory-rebuild
    description: Force a full memory index rebuild (openclaw memory index --force)
---

# Memory Rebuild

Force a full rebuild of the on-disk memory index using the active
embedding provider/model. The recovery path for
`DarojaAI/openclaw-gateway#21` — `memory_search` returning
`disabled: true, error: "index metadata is missing"` is fixed by a
full rebuild, since the index sidecar is rewritten as part of the
rebuild.

## When to use

- User says `/memory-rebuild`
- User reports `memory_search` returning
  `{"results": [], "disabled": true, "unavailable": true,
  "error": "index metadata is missing"}`
- The `memory-status` skill reports an agent in the `missing` or
  `mismatch` identity state with data present
- After a model swap in the gateway config (the embedder changed)
- After `MEMORY_CHECK_FAIL_ON_FRESH=1` fires in a deploy gate

## Command

```bash
openclaw memory index --force
```

Then verify:

```bash
openclaw memory status --json | jq '.[].status.custom.indexIdentity'
```

The rebuild is synchronous and may take a few seconds to a few
minutes depending on the corpus size. Output goes to stderr/stdout of
the gateway user journal (`journalctl --user -u openclaw-gateway`).

## Important warnings

Before running, check the current state — do not rebuild blindly:

1. **Confirm a rebuild is actually required.** Run `memory-status` first.
   - If every agent is `ok`, the index is healthy and there is nothing to rebuild.
   - If an agent is in `warn-fresh` (missing identity, no data), the
     rebuild will happen automatically on first-use — no action needed.
2. **Confirm the active provider is correct.** A rebuild writes a new
   index with the *active* provider. If the user just changed the
   gateway config and forgot to redeploy, the rebuild will bake in the
   wrong provider. Check `status.provider` vs `status.requestedProvider`
   first.
3. **If the active provider has no API key**, the rebuild will fail.
   `memory-rebuild` does NOT configure credentials — that's a separate
   concern (`OPENROUTER_API_KEY` in `~/.config/systemd/user/openclaw-gateway.service.d/override.conf`).

## What to report to the user

After the rebuild runs:

- **Exit code 0**: "Rebuild complete. Run `/memory-status` to verify the new index is healthy." Optionally re-run a known `memory_search` query to smoke test.
- **Exit code non-zero**: capture the full stderr and report it
  verbatim. The most common failure modes are:
  - **Auth error on the embedding model** — the gateway uses one
    `OPENROUTER_API_KEY` for both chat and embeddings; some embedding
    models on OpenRouter require a different key or a different
    provider account. Symptom: HTTP 401/403 from the embedding endpoint.
  - **Storage path not writable** — the configured memory path exists
    but `openclaw` cannot write to it. Symptom: `EACCES` or `EROFS`.
    Check the path in `~/.openclaw/openclaw.json` under
    `memory.storage.path`.
  - **Embedding model removed from catalog** — the model used to
    build the previous index is no longer in the active catalog.
    Symptom: "model not found" during rebuild. Fix: pick a stable
    embedding model in the gateway config and pin it explicitly so
    future model swaps don't invalidate the index.

## Forward-compat

If the underlying `openclaw memory index --force` command changes
(extra flags, new required arguments, etc.), report the failure to
the user and link to the troubleshooting doc — do not improvise.

## Related

- `memory-status` skill — call this first to confirm a rebuild is required
- `docs/troubleshooting/memory-index-disabled.md` — full recovery guide
- `scripts/post-deploy-verify-memory-index.sh` — the deploy gate that
  triggers this recovery flow
- `DarojaAI/openclaw-gateway#21` — original issue
- `openclaw/openclaw#90361` — root-cause upstream race
