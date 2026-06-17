# Per-Agent OpenRouter Keys

Per-agent OpenRouter API keys, provisioned once at deploy time, with
a USD-per-month spend cap and a hard reset boundary. This is the
replacement for the single `sk-or-…fe57` key that the gateway used
to share across all 16 agents.

## Why

A single shared key has two problems we kept hitting:

1. **No per-agent attribution.** The OpenRouter dashboard shows
   total spend but not which agent caused it. The cost monitor can
   attribute by reading trajectory files, but only after the fact,
   and only for spend that flows through the gateway. BYOK traffic
   and direct curl calls are invisible.
2. **No per-agent ceiling.** A runaway agent — a model loop, a
   misconfigured prompt, a bad tool — runs the shared key to its
   limit and the rest of the agents go dark. With per-agent
   limits, the worst case is one agent stops working for the
   remainder of the month.

## Architecture

```
                      OPENROUTER_PROVISIONING_KEY
                      (master / "management" key)
                                │
                                │  POST /api/v1/keys
                                │  {name: <agent>, limit: 10, limit_reset: monthly}
                                ▼
                      ┌──────────────────────┐
                      │ OpenRouter account   │
                      │ (single billing)     │
                      └──────────────────────┘
                                │
            ┌──────────┬────────┴────────┬──────────┐
            ▼          ▼                 ▼          ▼
        bond_nexus  dev_nexus       test_nexus   ... (16 total)
        $10/month   $10/month       $10/month
        reset 1st    reset 1st       reset 1st
            │          │                 │
            ▼          ▼                 ▼
   auth-profiles.json auth-profiles.json ...
   (chmod 0600)       (chmod 0600)
```

- One **master / provisioning key** lives in the systemd override
  at `~/.config/systemd/user/openclaw-gateway.service.d/override.conf`
  as `Environment=OPENROUTER_PROVISIONING_KEY=…`. It can create
  and revoke child keys but is never used to call models.
- N **child keys** (one per agent) live in
  `~/.openclaw/agents/<id>/agent/auth-profiles.json` (mode 0600,
  owned by the gateway user). Each carries a per-agent USD cap and
  a monthly reset on the OpenRouter side. The provisioning API
  returns the key string exactly once at creation — we persist it
  into `auth-profiles.json` at that moment.

## Lifecycle

### 1. Provision

`scripts/openrouter-provision.py provision --agent <id> --limit 10
--reset monthly` posts to `https://openrouter.ai/api/v1/keys` with
the master key in the `Authorization` header. The response carries
`data.key` — a single `sk-or-v1-…` string that OpenRouter will
never return again. Capture it immediately and write it into the
agent's `auth-profiles.json`.

Idempotency: re-running `provision` for an agent whose label
already exists is a no-op. OpenRouter does not expose a
rotate-by-label endpoint, so a re-provisioning requires a manual
`revoke --hash <hash>` first.

### 2. Store

The seed's `configure-openclaw-agent.sh` writes the captured key
into `auth-profiles.json` with the rest of the per-agent auth
config. That file is mode 0600 because the child key is a bearer
secret.

### 3. Use

Every model call from a given agent is authenticated with that
agent's child key. OpenRouter's per-key counters are the
authoritative source for "how much has this agent spent this
month" — the dashboard shows the per-key `usage` and
`usage_monthly` directly.

### 4. Monitor

`scripts/openrouter-provision.py list` returns a TSV of every
child key with its `usage_monthly` so the deploy and maintenance
scripts can spot agents approaching their cap. The cost monitor
(`/cost-report` skill) still reads trajectory files for per-model
attribution; the OpenRouter side provides the per-agent dollar
total that the trajectory files don't have natively.

For an at-a-glance per-agent read against the per-key limit, run
`/cost-report` — the per-agent `usage_monthly` value comes
straight from `openrouter-provision list` and is correlated
against the trajectory's `usage.cost.total`.

### 5. Revoke

`scripts/openrouter-provision.py revoke --hash <hash>` deletes
the child key. Used when:

- An agent is being removed.
- A child key leaked (the key string is in a file that was
  committed, or shared in a chat).
- The user wants to rotate an agent's key (revoke the old, then
  `provision` for a new one).

The `revoke` operation takes the **hash**, not the key string —
the hash is what `list` returns and what OpenRouter's `DELETE
/api/v1/keys/{hash}` expects.

## Deploy Integration

The seed's `configure-openclaw-agent.sh` is the deploy-time entry
point. It runs:

```bash
openrouter-provision sync --agents "bond_nexus,dev_nexus,test_nexus,…"
```

The `sync` subcommand lists every existing child key, then for
each agent id in the list that does NOT have a matching label, it
provisions a new key with the default limit
(`OPENROUTER_DEFAULT_AGENT_LIMIT`, default $10/month) and reset
(`OPENROUTER_DEFAULT_AGENT_RESET`, default `monthly`). The newly
provisioned keys are emitted as JSONL on stdout:

```
{"agent": "bond_nexus", "key": "sk-or-v1-…", "data": {…}}
{"agent": "dev_nexus",  "key": "sk-or-v1-…", "data": {…}}
```

The seed captures each line and writes the key value into the
agent's `auth-profiles.json`. Already-provisioned agents are
skipped silently (a "skipped N agent(s)" message goes to stderr
for the deploy log) — this is what makes `sync` safe to re-run on
every deploy.

The installer for the master key
(`scripts/install/install-openrouter-provisioning.sh`) is invoked
once, by hand, when the master key is first minted. It writes the
override, sets mode 0600, and reloads the systemd user daemon. It
is idempotent.

## Security Model

- **Master key** (`OPENROUTER_PROVISIONING_KEY`)
  - Lives in
    `~/.config/systemd/user/openclaw-gateway.service.d/override.conf`,
    mode 0600, owned by the gateway user.
  - Never logged, never echoed, never committed.
  - Can create and revoke child keys; cannot be used to call
    models directly (the OpenRouter dashboard will flag any
    model-bound request that uses a management key).
- **Child keys** (one per agent)
  - Live in
    `~/.openclaw/agents/<id>/agent/auth-profiles.json`, mode
    0600, owned by the gateway user.
  - Each carries a per-agent USD cap. OpenRouter enforces the
    cap server-side; the gateway does not need to second-guess
    it.
  - Visible in the OpenRouter dashboard under the
    "Provisioning > Keys" view, with per-key `usage`,
    `usage_monthly`, and `limit_remaining`.
- **The provisioning key file** (optional)
  - `/etc/openclaw/provisioning.key`, mode 0600, root-owned.
  - Read by the installer when the systemd override is being
    populated. The installer prefers the env var and only falls
    back to this file.

## Failure Modes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Missing API key` from the gateway after deploy | The seed's `configure-openclaw-agent.sh` ran but the `sync` did not produce a key for the agent | Run `openrouter-provision list` and check that the agent label is present; if not, run `provision` for that agent |
| `OpenRouter API POST /keys failed: HTTP 401` | The master key is missing, expired, or revoked | Re-run `install-openrouter-provisioning.sh` with a fresh master key; the new value will be picked up after `systemctl --user daemon-reload` and a service restart |
| `OpenRouter API POST /keys failed: HTTP 429` | The provisioning API is rate-limited (default: 10 req/min for new accounts) | Wait, then re-run; or stagger agent provisioning across multiple deploys |
| `Refusing to re-provision: a key with label=<id> already exists` | The agent was already provisioned (often: a re-deploy) | Expected. The seed's `sync` skips existing agents. If you intentionally want to rotate the key, `revoke --hash <hash>` first |
| Per-agent `usage_monthly` exceeds `limit` | An agent is over its cap | OpenRouter returns HTTP 402 for any further model call; the agent stops working until the monthly reset. Raise the limit with `provision --agent <id> --limit 50` (after revoking the existing key) |

## Related

- `scripts/openrouter-provision.py` — the CLI
- `scripts/install/install-openrouter-provisioning.sh` — the master-key installer
- `tests/openrouter-provision.bats` — the BATS test suite
- `config/skills/openrouter-provision/SKILL.md` — the
  `/openrouter-provision` Discord skill (provision / list /
  sync-all / revoke)
- `config/skills/cost-report/SKILL.md` — the `/cost-report` skill,
  which cross-references the per-key `usage_monthly` from
  `openrouter-provision list`
- Seed repo: `scripts/remote/configure-openclaw-agent.sh` — the
  deploy-time caller of `openrouter-provision sync`
