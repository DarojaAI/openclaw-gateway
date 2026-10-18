# ARchive Runbook — retiring the `DarojaAI/openclaw` fork

Standalone companion to `docs/upstream-staging/README.md` (the fork-delta
patch-of-record ledger, landed via PR #156). This runbook is the **actuate**
half: the exact, evidence-backed steps to archive the `DarojaAI/openclaw`
fork so the **only** remaining link to it is the three open upstream PR-head
branches, plus the pre-checks, post-archive verification, and the
unarchive-recovery path.

> Scope of the runbook: **archive only**. It does **not** close PRs, open
> PRs, or force-push the fork. Once archived, the fork is read-only but every
> ref (including the three PR heads) stays readable and cloneable — that is
> what makes archive (not delete) the correct action.

## Why the fork is safe to archive

The fork carries no unique runtime behavior that any deploy path depends on:

- The fleet installs `openclaw@<pin>` (resolved by
  `linux-desktop-seed/scripts/ci/resolve-openclaw-pin.sh`) **from npm
  upstream releases**, not from the fork.
- The fork's custom work is snapshotted losslessly under this
  `docs/upstream-staging/` directory (one `.patch` per fork commit/branch;
  see `README.md`, PR #156).
- Surviving fork fixes are already tracked upstream
  ([openclaw/openclaw#176062](https://github.com/openclaw/openclaw/issues/176062),
  [#176063](https://github.com/openclaw/openclaw/issues/176063)); the
  upstream-watch workflow tracks `openclaw/openclaw` only, so it is not
  affected by archiving.

After this runbook is executed, the fork's three PR-head branches are the
sole remaining fork reference anywhere in current code or tooling.

## The remaining link (intentional — kept after archive)

| fork branch | `gh api compare` (pre-archive, read-only) | purpose |
|-------------|-------------------------------------------|---------|
| `fix/issue-137` | status `diverged`, ahead 5 / behind 73 | retention config + vacuum (gateway #137) |
| `fix/issue-148` | status `diverged`, ahead 4 / behind 73 | `before_route_inbound_message` preflight hook (gateway #148) |
| `port/upstream-176062` | status `diverged`, ahead 1 / behind 76 | doctor auth re-archive fix port (upstream #176062) |

These three branches are **read-only while archived** but remain readable and
mergeable as comparison refs (GitHub preserves fork refs under archive). This
is the intended final state.

## Pre-checks — fork-reference sweep (this run, clean)

Sweep performed 2026-10-18 across both repos at their `origin/main` tips
(`linux-desktop-seed` @ `1f3bc39f`, `openclaw-gateway` @ `fd23710`), matching
`DarojaAI/openclaw` (and case variants) and excluding the retained
`openclaw-gateway` repo.

| repo | finding | classification |
|------|---------|----------------|
| seed | `.github/workflows/deploy.yml:1624`, `scripts/ci/purge-applied-proposals.sh:4` — comments describing the skill-workshop re-propose staging ground; both already point to this ledger as its disposition | prose (comment) — no action |
| seed | `MEMORY.md:156` — fork-demotion note ("archived after upstream PRs drain") | prose — no action |
| seed | `skills/openclaw-upstream-contribution/SKILL.md:272` — historical record of an already-opened fork PR | prose — no action |
| seed | `docs/plans/*` (`DarojaAI/openclaw-agent-workspace`, `-extensions`, `@darojaai/openclaw-coordination-plugin`) — references to **proposed distinct repos / npm package**, not the fork | out of scope — no action |
| gateway | all fork refs confined to `docs/upstream-staging/*.patch` and `README.md` — the intentional retirement ledger | intentional — keep |

Additional checks, all clean:

- **Watchers**: `config/upstream-watch-items.json` has `upstream_repo:
  "openclaw/openclaw"` only — **zero fork-watch entries**.
- **Submodules**: neither repo has a `.gitmodules`; no fork submodule.
- **Clone sources / secrets / scopes**: no deploy, install, verify, or CI
  script clones `DarojaAI/openclaw.git`; the only `openclaw` clones are
  `openclaw-gateway.git`. No token/scope is scoped to the fork.
- **`resolve-openclaw-pin.sh`**: resolves the pin from
  `DarojaAI/openclaw-gateway` (`OPENCLAW_GATEWAY_REPO`, default
  `DarojaAI/openclaw-gateway`), never from the fork — unaffected by archive.

Result: **no functional fork dependency exists**; only prose/historical
references remain, and the sole actionable fork link is the three PR-head
branches.

## Archive steps

### Option A — GitHub CLI (recommended, scriptable)

```bash
# 1. Archive the fork (idempotent; sets archived=true)
gh api -X PATCH repos/DarojaAI/openclaw -f archived=true

# 2. Confirm
gh api repos/DarojaAI/openclaw --jq '{name, archived, default_branch}'
#   expect: "archived": true
```

### Option B — GitHub web UI

`https://github.com/DarojaAI/openclaw` → **Settings** → **General** →
**Danger Zone** → **Archive this repository** → confirm.

> Neither path deletes any content. All branches, tags, PRs, issues, and the
> three PR-head refs remain intact and readable.

## Post-archive verification

Run all of the following after archiving:

1. **The three PR heads are still readable / mergeable** (compare endpoint
   works on archived repos):

   ```bash
   for b in fix/issue-137 fix/issue-148 port/upstream-176062; do
     gh api "repos/DarojaAI/openclaw/compare/openclaw:main...DarojaAI:$b" \
       --jq '{status, ahead_by, behind_by}'
   done
   #   expect the same status "diverged" and ahead/behind as the pre-check
   #   table (5/73, 4/73, 1/76) — i.e. the refs resolve and remain usable.
   ```

2. **`resolve-openclaw-pin.sh` still works** (the canonical pin lives in the
   gateway repo, not the fork):

   ```bash
   cd ~/GithubProjects/linux-desktop-seed
   OPENCLAW_PIN_SOURCE=gateway ./scripts/ci/resolve-openclaw-pin.sh test
   #   expect: prints a pin (e.g. "2026.10.x"), exit status 0
   ```

3. **Plan-only test dispatch is green** (dry-run deploy on `test`; it clones
   `openclaw-gateway`, never the fork):

   ```bash
   gh workflow run deploy.yml --repo DarojaAI/linux-desktop-seed \
     -f action=plan -f environment=test
   #   wait for completion, expect a passing run
   gh run watch <run-id> --repo DarojaAI/linux-desktop-seed --exit-status
   ```

4. **(Optional) Ledger still applies**: each
   `docs/upstream-staging/*.patch` remains `git apply --check`-able, so the
   fork's deltas are recoverable without the fork.

## Unarchive-recovery path (1 click)

If any maintainer change-request needs a fork write (new fix branch/PR from
the fork again), unarchive — contents and refs are untouched by archiving:

```bash
gh api -X PATCH repos/DarojaAI/openclaw -f archived=false
```

or UI: **Settings** → **Danger Zone** → **Unarchive this repository**.

## Known tradeoff (by design)

While archived:

- The three PR-head branches are **read-only**: you cannot push new commits
  to `fix/issue-137`, `fix/issue-148`, or `port/upstream-176062`, and no new
  fork PRs can be opened.
- Upstream delivery must go through `openclaw/openclaw` directly (the port
  PRs for #176062/#176063 plus the planned upstream PRs for #137/#148/#138).
  If a fork-side branch update becomes unavoidable, apply the one-click
  unarchive path above.

This tradeoff is accepted because the fork no longer serves any live deploy
path — it exists solely to stage the three upstream PR heads, which archive
preserves readably.