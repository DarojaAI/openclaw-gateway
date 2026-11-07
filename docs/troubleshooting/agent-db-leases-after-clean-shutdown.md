# Agent DB leases left behind by a clean shutdown

**Symptom:** the gateway logs `[shutdown] completed cleanly`, but the next start logs one
`agent database stale lease: owner-pid-dead; previous release not observed` line per agent and
runs a `process-death` integrity gate on every agent database. Tracked in
[#182](https://github.com/DarojaAI/openclaw-gateway/issues/182).

## Fix

Run OpenClaw **2026.10.10 or later**. 2026.10.8 and 2026.10.9 don't have the upstream fix.

1. Dispatch the LDS `upgrade-openclaw.yml` workflow with `stage=prepare`, `environment=test` and
   `target_version=2026.10.10` (or the current stable release). It runs the boot smoke and the
   fixture battery, then opens the pin PR here.
2. Merge the pin PR. Then run `stage=deploy` and do the checks under [Verify](#verify) on test
   before you promote to head or prod.

Don't hand-edit `config/openclaw-version.*` to skip Stage-0.

## Verify

Run these on the target VM after a graceful stop/start (a normal deploy restart counts):

1. **No leases survive the stop.** The deploy backup taken between stop and start is a copy of the
   state DB with no live writer. Read the copy, never the live file:

   ```bash
   b=$(ls -d ~/backups/*/ | tail -1)
   sqlite3 -readonly "$b/state/openclaw.sqlite.sqlite" \
     "select agent_id, owner_pid, datetime(opened_at/1000,'unixepoch') from agent_database_leases;"
   ```

   Expected: no rows. On 2026.10.8 after a dreaming run, you get one row per agent, all opened
   during the 03:00 sweep.

2. **The next start reports no stale leases:**

   ```bash
   journalctl CONTAINER_NAME=openclaw-gateway --since "<start time>" -o cat | grep -c 'stale lease'
   ```

   Expected: `0`.

3. **Shutdown receipts are written.** The receipts logged at the stop should say `written` (or
   `verification-missing` for an agent with no proof yet), not all `active-leases`.

Do the check after 03:00 UTC. The leak only appears once memory-core dreaming has swept the
agents. A restart before the nightly sweep looks clean on either version.

If the leases are gone but every agent still gates with `integrityGateReason=no-proof`, that's a
different cause. One known example is a host CLI at a different version re-stamping the proof
rows, which is fixed on the LDS side. It is not this leak.

## Cause

Upstream [openclaw/openclaw#168620](https://github.com/openclaw/openclaw/issues/168620) was fixed
by [#168631](https://github.com/openclaw/openclaw/pull/168631) (commit `cd6dbfa6`, merged
2026-10-13). The 2026.10.8 and 2026.10.9 release line forked before that commit, so neither
release has the fix. `v2026.10.10` and `v2026.11.1` do.

In 2026.10.8, the code path runs like this:

1. Memory-core dreaming lists each agent's session corpus with content revisions
   (`listSessionTranscriptCorpusEntriesForAgent(agentId, { includeRetainedSqlite: true })`, and
   `includeContentRevision` defaults to on).
2. The inventory runs in the pooled `session-transcript.worker`
   (`readSessionTranscriptCorpusInventory`). Its session rows are read through the read-only
   reader, but the projection gets the caller's options without `readOnly`.
3. Each SQLite transcript's revision goes through `readTranscriptContentRevisionSync`. That
   calls the **writable** `readTranscriptStatsSync`, which calls `openOpenClawAgentDatabase`.
   The worker claims an agent-database lease and caches the handle in its own handle cache.
4. Gateway shutdown closes the main thread's agent databases. Nothing releases the worker's
   cached handles, so their lease rows outlive the process. The shutdown still reports
   `completed cleanly`.
5. On the next start, every one of those rows is a dead-owner lease. The claim path logs
   `stale lease: owner-pid-dead`, revokes the integrity proof and gates the database.

While the leaked lease exists, every other close of that database also logs
`clean-close receipt: active-leases` instead of writing a clean-close proof.

In 2026.10.10 the inventory passes `readOnly: true` through the projection. Revisions then come
from `readTranscriptStatsBatchReadOnlySync`, which never joins the writable lifecycle, so no
lease is claimed. Both releases were checked in the npm tarballs.

## Evidence (prod, 2026-11-07, gateway 2026.10.8)

- The deploy backup `backups/20261107T045612Z` was taken after the 04:55:34 `completed cleanly`
  stop and before the 04:57 start. It holds **26** `agent_database_leases` rows, all owned by the
  stopped gateway pid. They were opened between **03:00:10 and 03:01:51**, one per agent. That
  is the window between memory-core's first `normalized recall artifacts before dreaming` line
  (03:00:12) and `dreaming promotion complete (workspaces=26 …)` (03:01:51).
- The next start logged 26 `stale lease: owner-pid-dead` lines and 26 integrity gates.
- From 03:00 until the stop, every clean-close receipt in the journal was `active-leases`
  (393 between 03:00 and 04:00, 400 between 04:00 and the stop). Before 03:00, most receipts
  were `written` or `verification-missing`. The leaked leases were held for about two hours,
  longer than the 30-minute idle handle TTL.
- At the stop, the main thread closed its own 26 handles. All 26 receipts were `active-leases`,
  so the leaked rows didn't belong to the main-thread cache.
- Control cases: the stops at 2026-11-07 00:40, 01:25 and 17:23 had no sweep since their start.
  Each pre-start backup holds zero lease rows, and none of the following starts logged a stale
  lease.
- The gateway stopped at 2026-11-06 21:24 had been up since before the earliest journal entry
  (13:00). Every receipt it logged was `active-leases`, and the next start logged 26 stale leases.
  That fits the same leak, but no backup exists to confirm the rows.

## Not covered by the upgrade

On 2026-11-06 a gateway started at 21:28 and was stopped at 21:29:43, before its background
stale-lease recovery had finished. The start after it again logged 26 stale leases, with no sweep
involved. No backup exists for that gap, so the owner of those rows is unconfirmed. The likely
cause is that the stop interrupted worker-held integrity verification and the worker's leases
never got released. That would be the same shutdown gap with a different source. 2026.10.10
doesn't change it. To avoid it, don't restart a gateway while its post-start integrity
verification is still running.

## Related

- [#159](https://github.com/DarojaAI/openclaw-gateway/issues/159): the cost of stale-lease gates
  after an unclean shutdown (upstream #176342).
- Upstream gap that remains after the fix: gateway shutdown doesn't release or report the
  agent-database leases that pooled workers still hold under its pid. Any worker-held writable
  open at stop time leaks silently behind a `completed cleanly` line (see
  [Not covered by the upgrade](#not-covered-by-the-upgrade)).
