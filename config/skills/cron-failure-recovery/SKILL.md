---
name: "cron-failure-recovery"
description: "On any cron failure (Exec failed, timeout, delivery failed), self-diagnose via cron get/runs + sessions_history, fix the smallest possible cause, ship as PR. The canonical creation path is `scripts/cron/cron-add.sh` (PR #1423); this skill owns recovery, not creation."
license: GPL-3.0
domain: self-improvement
consumers:
  - daroja-coding-agent
related_skills:
  - session-anomaly-capture
  - cron-self-management
  - cron-trigger-pattern
---

# Cron Failure Recovery

## Why this skill exists

Three cron failures in 4 days of the consumer-repo-scan cron (id `0bae8103-...`, schedule `0 14 * * *`):
- 14:03 UTC 2026-08-14: `Exec failed: gh api ... run-fetches`. No delivery. Owner notification didn't reach operator for ~12 min.
- 11:48 UTC and earlier: 4× `cron: job execution timed out (last phase: model-call-started)`. Each 300s timeout.
- Across last 30 runs: 7 errors total, 19 ok. Failure rate 23%. The cron is genuinely flaky.

Each one, I should have caught autonomously within minutes of the moment it fired. Instead I waited for the operator to point at it.

## Creation path is the cron-job-kit, not this skill

This skill owns **recovery**, not **creation**. For creation, see:

- `scripts/cron/cron-add.sh` (DarojaAI/linux-desktop-seed PR #1423) — JSON-spec wrapper that gates `cron add` behind schema validation, post-create read-back, and auto-rollback on drift. Catches the four foot-gun classes the bare call silently skips (sessionTarget×payload.kind mismatch, naive-ISO `at`, every-N-without-trigger, post-create drift).
- `docs/cron-job-spec.md` — input contract, validation gates, exit codes.
- `tests/cron-add.bats` — 14-test regression suite.

If a recovery here surfaces a creation-time bug (Bucket D: payload escaping, Bucket A: gh command shape), fix the wrapper, not this skill.

## When to load

- On any inbound containing "⚠️ Cron job … failed" or delivery-failed notice.
- On session-startup if `cron action=list` shows any `lastRunStatus != ok`.
- NEVER on healthy cron runs (don't spam the channel).

## Procedure

1. Pull diagnostics:
   - `cron action=get jobId=...`
   - `cron action=runs jobId=... limit=5`
   - `sessions_history sessionKey="<last-failed-run-session>"` if present
2. Classify the failure into one of five buckets. Each has its own fix shape:

   **Bucket A — `Exec failed: gh ...`**
   Model-side gh command construction failed. Likely cause: jq syntax error, missing `-q` flag, expired token, or repo moved. Fix: don't ship a "maybe right" model-generated string. Reproduce the failing command in `bash` directly, rebuild the working invocation, store as a script under `scripts/cron/`.

   **Bucket B — `cron: job execution timed out (last phase: model-call-started)`**
   LLM hang. Causes: prompt too long, missing `--light-context`, API rate limit pressure. Fix: shorten prompt, raise timeout only with explicit operator OK, add `--light-context` flag pair.

   **Bucket C — `deliveryStatus: not-delivered`**
   Discord channel lost access, agent no longer bound, or `delivery.mode` misconfigured. Fix: verify `session_status`, re-check binding via `gateway action=config`, re-set delivery. Do not blindly retry.

   **Bucket D — Repeated identical `Exec failed` on `jq` or shell tool**
   Operator-visible bug in the cron payload string itself (escaping, placeholder substitution). Fix: rewrite the payload to a shell-script wrapper under `scripts/cron/` cited from the `payload.message`. If the underlying spec would have been rejected by `cron-add.sh`, fix the spec, not the payload.

   **Bucket E — Unknown**
   Do NOT invent. Add to `### Unknowns` of the recovery entry. Escalate with `message(action=send)` if severity is high.

3. Pick the **smallest fix** size:
   - Prompt edit (1-3 lines): preferred for Bucket B.
   - Payload rewrite: Bucket A if the command shape is wrong.
   - New script under `scripts/cron/`: Bucket A/D if the model-side construction is the symptom.
   - Delivery config: Bucket C.
   - Spec rewrite via `cron-add.sh`: Bucket D when the underlying spec violates a schema gate.

4. Ship as a PR into the cron-owner's repo (this one for own crons, sibling-agent's repo for sibling-agent crons — coordinated via the cross-agent propagation pattern in PR description).

5. Append a one-line entry under `## Cron failure recovery` in today's daily with: bucket letter, action taken, PR link.

6. PR scope:
   - Body describes bucket + root cause + fix + rollback
   - Single commit
   - Branch `daroja-coding-agent/fix-cron-<bucket>-<short-slug>`

7. Skip if operator is already debugging (`cron action=runs` shows recent operator-driven activity within the same bucket). Don't double-work.

## Acceptance criteria

- Cron-failure-notification to PR-open: median ≤10 min for buckets A/D, ≤20 min for B/C/E.
- Recovery entries ≤5 lines each.
- Zero fabricated root causes. If a bucket isn't in the list, escalate.
- ≥80% of cron failures get an automated recovery attempt before operator intervention.
- Bucket D recoveries route through `scripts/cron/cron-add.sh` so the spec gates run at recovery time, not just at creation time.

## Integration

- `session-anomaly-capture` Phase 0 calls `cron action=list` first — already wired via the `cron-went-silent-too` detection there.
- After recovery, `commit-time-reflection` captures the per-commit lesson in the daily.
- After recovery of sibling-agent's cron, `cross-agent-lesson-propagation` (future skill) propagates the pattern.
- `scripts/cron/cron-add.sh` is the structural enforcement point — Bucket D fixes ship through it so the same spec error cannot recur.

## Cross-references

- AGENTS.md → "Self-improvement discipline is the differentiator" (MEMORY entry #5). This skill is the cron-side half.
- AGENTS.md → "Skills are documentation, not enforcement" — recovery is described here; the gates live in `scripts/cron/cron-add.sh`.
- OpenClaw hint from prior session: "save it as a skill via skill_workshop if the user agrees." Operator approval: 14:19 UTC "apply".

## Why not a heartbeat cron?

Could in principle run this skill on its own cron. But the trigger is "any cron failed, recently" — a trigger that already has data in `cron action=list`. On-demand at session-startup + on inbound cron-failure notice is sufficient.
