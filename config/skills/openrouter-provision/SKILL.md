---
name: openrouter-provision
description: "Provision, list, sync, and revoke per-agent OpenRouter API keys. Use when the user asks about provisioning an OpenRouter key for an agent, listing existing keys, syncing keys for a set of agents, or revoking a key. Backed by scripts/openrouter-provision.py using a single master/provisioning key with N child keys (one per agent) carrying a per-agent USD spend limit and a monthly reset. See docs/concepts/per-agent-openrouter-keys.md for the full architecture."
---

# OpenRouter Provision

Discord bridge to the `openrouter-provision.py` CLI. Exposes four
subcommands — `provision`, `list`, `sync-all`, `revoke` — that map
1:1 to the CLI's `provision`, `list`, `sync --agents <all>`, and
`revoke` subcommands.

## When to Use

- User asks to provision a new OpenRouter key for an agent
- User asks how many keys are currently provisioned
- User asks to sync / reconcile keys with the current agent list
- User asks to revoke a key for a specific agent
- Any operation on the per-agent OpenRouter keys described in
  `docs/concepts/per-agent-openrouter-keys.md`

## Subcommands

### `provision <agent>`

Provisions a new child key for one agent. Optional `--limit` (USD,
default 10) and `--reset` (monthly/weekly/daily, default monthly)
override the per-call defaults; the env vars
`OPENROUTER_DEFAULT_AGENT_LIMIT` and `OPENROUTER_DEFAULT_AGENT_RESET`
set the cross-call defaults.

```bash
/usr/local/bin/openrouter-provision provision --agent <agent> [--limit 25] [--reset weekly]
```

Output is a single JSON line on stdout:

```
{"existed": false, "label": "<agent>", "key": {"key": "sk-or-v1-…", …}}
```

If a key with the same label already exists, the response is
`{"existed": true, …}` and no new key is created. To rotate, first
`revoke` the existing key by its hash, then `provision` again.

### `list`

Returns a TSV table of every child key under this account:

```
hash	label	limit	limit_reset	usage_monthly
hash-1	bond_nexus	10.0	monthly	2.5
hash-2	dev_nexus	25.0	weekly	0.0
```

Use this to find the hash for a `revoke` call, and to see
per-agent monthly usage at a glance.

### `sync-all`

Provisions keys for every agent in the gateway's known agent list.
The agent list is read from the same source the seed's
`configure-openclaw-agent.sh` uses — the agent ids in
`config/openclaw-defaults.json`'s `agents.list` array. Already-
provisioned agents are skipped; only the missing ones are created.
Output is JSONL on stdout, one line per newly-provisioned agent.

```bash
/usr/local/bin/openrouter-provision sync --agents "$(jq -r '.agents.list[]' ~/.openclaw/openclaw.json | paste -sd,)"
```

(That one-liner is the canonical `sync-all` invocation; the skill
just calls it and surfaces the output.)

### `revoke <agent>`

Looks up the agent's key hash with `list` and revokes it. The
skill needs the hash, not the agent id, so it runs `list` first
and greps for the matching label.

```bash
hash="$(openrouter-provision list | awk -v a="<agent>" '$2 == a {print $1}')"
/usr/local/bin/openrouter-provision revoke --hash "$hash"
```

If the agent has no key, the skill returns an informative "no key
found for agent" message rather than a confusing empty output.

## What It Returns

Each subcommand returns its raw CLI output to Discord. The skill
does not transform the output — `openrouter-provision.py` is
already shaped for machine consumption (JSON / JSONL / TSV), and
Discord's code-fence rendering makes it readable inline.

For human-facing summaries, pair with the `cost-report` skill,
which cross-references `openrouter-provision list` against the
trajectory file data to show per-agent spend against the
per-key `limit`.

## Security and Idempotency Notes

- The master key (`OPENROUTER_PROVISIONING_KEY`) is read from the
  systemd user override, never from the command line. The skill
  does not accept a key as an argument.
- The skill never logs the master key, and `openrouter-provision.py`
  never logs it either. The skill surfaces only the per-agent
  child key strings, which are already considered user-visible
  (they sit in `auth-profiles.json` mode 0600).
- `provision` and `sync-all` are idempotent on label. Re-running
  them does not create duplicate keys.

## Related

- `scripts/openrouter-provision.py` — the CLI
- `scripts/install/install-openrouter-provisioning.sh` — the
  master-key installer
- `tests/openrouter-provision.bats` — the BATS test suite
- `docs/concepts/per-agent-openrouter-keys.md` — the
  end-to-end architecture, security model, and failure modes
- `cost-report` skill — for per-agent spend attribution against
  the per-key limit
