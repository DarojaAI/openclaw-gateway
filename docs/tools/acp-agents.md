# ACP Agents — Multi-Agent ACP Runtime Bindings

How OpenClaw agents delegate `write`/`edit` work to an external ACP
coding harness (opencode via the `acpx` backend) in this gateway repo.

## Where the Pattern Lives

Per-agent entries live at `agents.entries.<id>` in the canonical L3b
template `config/openclaw-defaults.json` (schema:
`agents.entries.*` in `linux-desktop-seed`'s
`schemas/openclaw-config.schema.json`).

Three agents land ACP runtime bindings (Issue #118):

| agent id | workspace | harness |
|---|---|---|---|
| `daroja_coding_agent` | `/home/desktopuser/GithubProjects/daroja-coding-agent` | opencode (`acpx`) |
| `darojaai_architect` | `/home/desktopuser/GithubProjects/darojaai_architect` | opencode (`acpx`) |
| `ai_governance` | `/home/desktopuser/GithubProjects/ai-governance` | opencode (`acpx`) |

```json
"agents": {
  "entries": {
    "daroja_coding_agent": {
      "workspace": "/home/desktopuser/GithubProjects/daroja-coding-agent",
      "runtime": {
        "type": "acp",
        "acp": {
          "agent": "opencode",
          "backend": "acpx",
          "mode": "persistent"
        }
      }
    }
  }
}
```

### Shape Rules (A3)

- `workspace` — VM clone dir for the agent's codebase (set for
  every ACP entry; the harness operates inside it).
- `runtime.type = "acp"` — external ACP harness, not the embedded runtime.

- `runtime.acp.agent = "opencode"` — harness agent id.

- `runtime.acp.backend = "acpx"` — backend adapter (falls back to
  global `acp.backend` when omitted).
- `runtime.acp.mode = "persistent" | "oneshot"` — **the schema enum
  is `persistent` | `oneshot` only** (see `AgentRuntimeAcpConfig` in
  the installed OpenClaw 2026.8.2
  `dist/types.openclaw-*.d.ts:2073-2081`, and `agents.entries.*.runtime.acp.mode`
  in the config schema). A "session"-flavored long-lived coding
  agent is expressed as `persistent`; the runtime rejects any other value.

  
- **No `cwd`** on the entry — ACP sessions default to the entry's
  `workspace`. A separate `cwd` is only set when a session must
  diverge from the workspace (schema allows it under
  `runtime.acp.cwd`, but the canonical entries don't use it).

## Per-Agent OpenRouter Keys — auth-profiles Sync

Model traffic for each ACP agent authenticates with the agent's **child key**,
never the master key. The mechanism implemented in
`scripts/openrouter-provision.py`:

- `sync --agents <csv>` (`scripts/openrouter-provision.py:10-23`)
  is the deploy-time entry point: lists existing child keys,, provisions
  one per missing agent, and emits each newly-provisioned key as JSONL
  on stdout — "so the caller can capture each key string and write it
  into the agent's `auth-profiles.json`" (`:566-573`).
- The caller (seed's `configure-openclaw-agent.sh`) writes the child key
  into `~/.openclaw/agents/<id>/agent/auth-profiles.json` (mode 0600)
  — the per-agent credential store the harness + gateway use.
- The master key (`OPENROUTER_PROVISIONING_KEY`) is a management-only
  credential for `POST/GET/DELETE /api/v1/keys`; it is never wired into
  spawned sessions. The only child-key-authenticated call is `key_info`
  (`scripts/openrouter-provision.py:436-442`).

See `docs/concepts/per-agent-openrouter-keys.md` for the full lifecycle
(the provisioning key installer lives at
`scripts/install/install-openrouter-provisioning.sh`).

## Discord Channel Bindings — Env-Var Flow

Discord routing for these entries uses the top-level `bindings` array
in the L3b template with a clearly marked env placeholder (never a
hardcoded snowflake;

```json
"bindings": [
  {
    "type": "route",
    "agentId": "daroja_coding_agent",
    "match": {
      "channel": "discord",
      "peer": { "kind": "channel", "id": "__OPENCLAW_DISCORD_CHANNEL_ID__" }
    }
  }
]
```

The `__OPENCLAW_DISCORD_CHANNEL_ID__` placeholder follows the template's
existing env-substitution convention (`__DISCORD_BOT_TOKEN__`,
`__OPENROUTER_API_KEY__`, `${A2A_*_TOKEN}`)) and is replaced at deploy
with the per-environment value of **`OPENCLAW_DISCORD_CHANNEL_ID`**
(primary Discord channel for that env; one GitHub env var per
environment — test / head / prod.

On VMs where the bind chain needs distinct per-agent channels, the seed's
per-repo `OPENCLAW_<ENV>_DISCORD_CHANNEL` GitHub actions variables
(`scripts/openclaw-bind-repos.sh` Phase 1/4) override the template
bindings at bind time. The template placeholder exists so the config
stays env-agnostic and schema-valid between deploys.



## Verification

```bash
python3 -c "import json; json.load(open('config/openclaw-defaults.json'))"
# Schema check (same as tests/openclaw-defaults.bats):
python3 scripts/merge-openclaw-config.py --validate   # when the validator exists
```