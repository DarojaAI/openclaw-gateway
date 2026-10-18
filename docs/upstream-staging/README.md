# upstream-staging — fork delta patch-of-record

Phase 1 artefact for retiring the `DarojaAI/openclaw` fork. Every fork delta
(8 commmits ahead of `openclaw/openclaw` `main`, plus in-flight retention
branches) is snapshotted here as a `.patch`, one per fork commit / branch. The
table is the provenance + triage ledger. All patches are `git apply`-able and
were byte-downloaded from GitHub `.patch` endpoints; the branch snapshots are
`openclaw:main...DarojaAI:<branch>` diffs.

> Purpose: preserve the fork's custom work losslessly so the fork can later be
> archived. Actual upstream PRs are opened by the orchestrator; **do not open PRs
> from this branch.**

## Ledger

| file | fork provenance | gateway issue ref | triage state |
|------|-----------------|-------------------|--------------|
| `23e039cd-feat-hooks-message-sending-pre-send-gate-API-1.patch` | fork PR #1 (commit `23e039cd`), merged 2026-08-21 | — (feature reverted on fork) | **SUPERSEDED / REVERTED on fork** (PR #6); upstream evolved its own receipts hooks. No net delta to port. |
| `a056c192-feat-outbound-wire-message-sending-gate-into.patch` | fork PR #2 (commit `a056c192`), merged 2026-08-21 | — (feature reverted on fork) | **SUPERSEDED / REVERTED on fork** (PR #5). No net delta. |
| `bd633af0-feat-pr-gate-workspace-extension-implementing-RFC.patch` | fork PR #3 (commit `bd633af0`), merged 2026-08-21 | — (feature reverted on fork) | **SUPERSEDED / REVERTED on fork** (PR #4). No net delta. |
| `83858a14-Revert-feat-pr-gate-workspace-extension-implementing-RFC.patch` | fork PR #4 (commit `83858a14`), merged 2026-08-21 | — | **REVERT** — cancels PR #3. Kept only for complete history. |
| `b6b94ed4-Revert-feat-outbound-wire-message-sending-gate-into.patch` | fork PR #5 (commit `b6b94ed4`), merged 2026-08-21 | — | **REVERT** — cancels PR #2. Kept only for complete history. |
| `d1413af1-Revert-feat-hooks-message-sending-pre-send-gate-API-1.patch` | fork PR #6 (commit `d1413af1`), merged 2026-08-21 | — | **REVERT** — cancels PR #1. Kept only for complete history. |
| `607aabf8-fix-doctor-scope-plugin-npm-root-scan-to-ledger-owned-roots.patch` | fork PR #8 (commit `607aabf8`) | [#143](https://github.com/DarojaAI/openclaw-gateway/issues/143) | **SURVIVES upstream** (partially mitigated) — upstream issue filed: [openclaw/openclaw#176063](https://github.com/openclaw/openclaw/issues/176063); **port PR follows** (see verdicts below). Not merged upstream — SHA resolves only via fork PR ref, diverged from `main`. |
| `92270bf8-fix-doctor-stop-re-snapshotting-already-migrated-auth.patch` | fork PR #9 (commit `92270bf8`) | [#132](https://github.com/DarojaAI/openclaw-gateway/issues/132) | **SURVIVES upstream** — upstream issue filed: [openclaw/openclaw#176062](https://github.com/openclaw/openclaw/issues/176062); **port PR follows** (see verdicts below). Upstream's evolved receipts code still only does a boolean receipt check. |
| `issue-137-retention-wip.patch` | `DarojaAI/openclaw` branch `fix/issue-137` vs `openclaw/openclaw` `main` | [#137](https://github.com/DarojaAI/openclaw-gateway/issues/137) | **IN-FLIGHT** (retention config + vacuum). Upstream PR planned on delivery. |
| `issue-138.patch` | `DarojaAI/openclaw` branch `fix/issue-138` vs upstream `main` | [#138](https://github.com/DarojaAI/openclaw-gateway/issues/138) | **IN-FLIGHT** (RSS creep / event-loop stall, ownership wedge, Discord outage). Upstream PR planned on delivery. |
| `issue-transcript-retention-vacuum.patch` | `DarojaAI/openclaw` branch `fix/transcript-retention-vacuum` vs upstream `main` | [#137](https://github.com/DarojaAI/openclaw-gateway/issues/137) | **IN-FLIGHT** (transcript-archive retention + vacuum). Upstream PR planned on delivery. |

### Branch snapshots that 404'd (not saved, recorded for completeness)

| branch | note |
|--------|------|
| `fix/issue-148` | `https://github.com/openclaw/openclaw/compare/main...DarojaAI:fix/issue-148.patch` returned HTTP 404 — branch does not exist on the fork. Gateway issue [#148](https://github.com/DarojaAI/openclaw-gateway/issues/148) (the `before_route_inbound_message` preflight hook) is still open and tracked in the gateway; no fork patch to snapshot. |

## Triage verdicts (evidence-checked vs upstream `main` @ `d3dc09e`)

Per-file verdicts for the doctor-scope patch set (`607aabf8` / PR #8 and
`92270bf8` / PR #9). Recommended action per row: **upstream issue filed, port PR
follows** (no further verification needed before porting).

| file | verdict | evidence (upstream `main` @ `d3dc09e`) | recommended action |
|------|---------|------------------------------------------|--------------------|
| `doctor-auth-flat-profiles.ts` (PR #9 / #132) | **SURVIVES** | upstream still **re-archives reappeared identical sources** — `doctor-auth-flat-profiles.ts:544-556` uses only a **boolean receipt check** (no source-reappearance guard), so the fix is needed as-is | upstream issue filed: [#176062](https://github.com/openclaw/openclaw/issues/176062); **port PR follows** |
| npm-root scoping — `npm-project-roots.ts` (PR #8 / #143) | **SURVIVES (partially mitigated)** | upstream added manifest-ownership gating, but `install-paths.ts` `isPluginNpmProjectDir` still admits `^g-[a-f0-9]{16}$` generation trees; **no installRecords filter** | upstream issue filed: [#176063](https://github.com/openclaw/openclaw/issues/176063); **port PR follows** |
| `doctor-plugin-host-links.ts` (PR #8 / #143) | **SURVIVES** | both audit and repair still enumerate the **full root set** (no scoping) | upstream issue filed: [#176063](https://github.com/openclaw/openclaw/issues/176063); **port PR follows** |
| `doctor-sqlite-maintenance-lock.test.ts` (PR #8 / #143) | **MOOT — DROP** | upstream `gateway-lock.ts` already has **dead-owner reclaim + startTime identity**, so this test's concern is obsolete | do not port |
| `post-core-plugin-convergence` (PR #8 / #143) | **SURVIVES (adapted)** | file **moved upstream** to `src/commands/doctor/shared/post-core-plugin-convergence.ts`; unscoped walk survives at **line 108** | upstream issue filed: [#176063](https://github.com/openclaw/openclaw/issues/176063); **re-PR adapted to new location** |

Note: `607aabf8` was confirmed **diverged** from upstream `main` (`gh api
.../compare/main...607aabf80410` → `status: diverged`, never merged; the SHA
resolves only via a fork PR ref). The earlier "ALREADY UPSTREAM" marking was
incorrect and has been corrected here.

## Derived fork PR mapping (for reference)

| fork PR | title | commit(s) |
|---------|-------|-----------|
| #1 | feat(hooks): message:sending pre-send gate API | `23e039cd` |
| #2 | feat(outbound): wire message-sending gate into executeSendAction | `a056c192` |
| #3 | feat(extension): pr-gate workspace plugin | `bd633af0` |
| #4 | Revert pr-gate | `83858a14` |
| #5 | Revert gate-wire | `b6b94ed4` |
| #6 | Revert message-sending-gate-api | `d1413af1` |
| #8 | fix(doctor): scope plugin npm-root scan (→ gw #143) | `607aabf8` |
| #9 | fix(doctor): stop re-snapshotting migrated auth (→ gw #132) | `92270bf8` |

## Regenerate

```bash
# 8 fork-main commits (SHAs from: gh api repos/openclaw/openclaw/compare/main...DarojaAI:main --jq '.commits[].sha')
for sha in 23e039cdd8f5 a056c192bc8c bd633af0f4e7 b6b94ed434aa \
           d1413af1cca3 83858a149221 607aabf80410 92270bf81e3a; do
  curl -sL "https://github.com/DarojaAI/openclaw/commit/${sha}.patch" -o "docs/upstream-staging/${sha:0:8}-<slug>.patch"
done
# in-flight branches (404 = branch absent)
curl -sL "https://github.com/openclaw/openclaw/compare/main...DarojaAI:fix/issue-137.patch" -o docs/upstream-staging/issue-137-retention-wip.patch
curl -sL "https://github.com/openclaw/openclaw/compare/main...DarojaAI:fix/issue-138.patch"     -o docs/upstream-staging/issue-138.patch
curl -sL "https://github.com/openclaw/openclaw/compare/main...DarojaAI:fix/transcript-retention-vacuum.patch" -o docs/upstream-staging/issue-transcript-retention-vacuum.patch
```