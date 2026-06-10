# OpenClaw Architecture — Canonical Reference

> **Last updated:** 2026-05-24
> **Status:** PRODUCTION — test, head, and prod all verified working
> **Violating any rule in this document will break the deploy pipeline.**

---

## The DAT Contract (Non-Negotiable)

**All environment-specific data MUST come from GitHub environment variables/secrets.**

`config/openclaw-ideal-config.json` contains **NO** hardcoded:
- Discord channel IDs
- Discord guild IDs
- Discord user IDs
- Bot tokens
- API keys

The ideal config is a **template**. Environment-specific values are injected at deploy time via `scripts/ci/generate-openclaw-env-overrides.py`.

**If you hardcode an ID in ideal config, every environment gets it. This causes bots to respond in wrong channels.**

---

## Environment Topology

| Environment | VM IP | Bot Name | Bot Client ID | Channel | Purpose |
|---|---|---|---|---|---|
| **test** | 178.105.6.42 | `co` | 1485038437395599460 | 1493278190540427395 | CI validation |
| **head** | 178.105.6.47 | `burns` | 1494810520950145044 | 1496398999928967238 | Pre-prod testing |
| **prod** | 204.168.182.32 | `coder` | (see secrets) | 1492701850217218268 | Live production |

**One bot per environment. Never share tokens across environments.**

---

## Config Pipeline (6 Steps)

```
1. config/openclaw-ideal-config.json
   → Source template (NO env-specific data)

2. scripts/ci/generate-openclaw-env-overrides.py
   → Reads GitHub env vars, produces /tmp/env-overrides.json
   → Env vars: OPENCLAW_DISCORD_GUILD_ID, OPENCLAW_DISCORD_CHANNEL_ID,
               OPENCLAW_DISCORD_ALLOWED_USER, DISCORD_BOT_TOKEN, OPENROUTER_API_KEY

3. scripts/merge-openclaw-config.py
   → Deep-merges ideal-config + env-overrides → /tmp/openclaw-env-merged.json
   → Arrays: override wins (except agents.list and bindings which dedupe)

4. scripts/ci/copy-deploy-artifacts.sh
   → SCPs merged config to VM as /tmp/config/openclaw-env.json

5. scripts/remote/merge-openclaw-config.py
   → Replaces ~/.openclaw/openclaw.json ENTIRELY (not a merge)

6. scripts/openclaw-bind-repos.sh (only if OPENCLAW_TARGET_REPOS set)
   → Creates per-agent bindings + auth-profiles.json in agent dir
```

**Critical:** Step 5 replaces the file entirely. Step 3's merge behavior does NOT apply to the live config replacement.

---

## Model Configuration

### `models.mode` — MUST be `"merge"`

```json
"models": {
  "mode": "merge",
  "providers": {
    "openrouter": {
      "baseUrl": "https://openrouter.ai/api/v1",
      "apiKey": "${OPENROUTER_API_KEY}",
      "api": "openai-completions",
      "injectNumCtxForOpenAICompat": true,
      "headers": {
        "HTTP-Referer": "https://github.com/patelmm79/ubuntu-8gb-hel1-1",
        "X-Title": "ubuntu-8gb-hel1-1"
      },
      "models": []
    }
  }
}
```

- `"merge"` = gateway catalog + explicit models coexist
- `"replace"` + empty `models` array = `FailoverError: Unknown model`
- `generate-openclaw-env-overrides.py` MUST NOT set `models.mode` (was bug #450)

### Model Aliases

| Alias | Full Model ID | Use Case |
|---|---|---|
| `ensign` | `openrouter/anthropic/claude-haiku-4.5` | Default, fast |
| `reasoning` | `openrouter/anthropic/claude-sonnet-4.5` | Complex reasoning |
| `speedy` | `openrouter/morph/morph-v3-fast` | Quick responses |
| `coding` | `openrouter/minimax/minimax-m2.7` | Code generation |
| `kimi` | `openrouter/moonshotai/kimi-k2.6` | Long context |

**Note:** `compaction.model` uses dash (`claude-haiku-4-5`) not dot (`claude-haiku-4.5`). Gateway auto-enables the `anthropic` plugin based on compaction model.

### Model ID Prefix Handling

- Config uses `openrouter/anthropic/claude-haiku-4.5` (WITH prefix)
- Gateway's `normalizeOpenRouterModelId()` STRIPS `openrouter/` before API call
- Provider routing: `anthropic` → `auth.order["anthropic"] → openrouter:default`

---

## Auth Architecture

Two files work together:

### 1. `~/.openclaw/openclaw.json` — `auth.order`

Maps provider names → auth profile names:

```json
"auth": {
  "profiles": {
    "openrouter:default": { "provider": "openrouter", "mode": "api_key" },
    "anthropic:default": { "provider": "openrouter", "mode": "api_key" }
  },
  "order": {
    "anthropic": ["openrouter:default"],
    "openrouter": ["openrouter:default"]
  }
}
```

**Schema note:** Top-level `auth.profiles` uses `mode` (not `type`).

### 2. `~/.openclaw/agents/<agent>/agent/auth-profiles.json` — Credentials

```json
{
  "openrouter:default": {
    "type": "api_key",
    "apiKey": "sk-or-v1-..."
  }
}
```

**Schema note:** Agent-level auth-profiles uses `type` (not `mode`).

**Both files must exist.** `auth.order` without `auth-profiles.json` = "Missing API key" error.

---

## Discord Response Delivery

### `messages.groupChat.visibleReplies`

```json
"messages": {
  "groupChat": {
    "visibleReplies": "automatic"
  }
}
```

**MUST be `"automatic"`**. Without this, OpenClaw generates responses but sets `didSendViaMessagingTool: False`, suppressing Discord delivery.

### Channel Resolution

Gateway startup logs show:
- `discord channels resolved: ...` = bot can see the channel, will respond
- `discord channels unresolved: ...` = bot cannot see the channel, will NOT respond

**Causes of unresolved:**
1. Bot not invited to server
2. Bot missing "View Channel" permission for that channel
3. Channel doesn't exist

---

## Commands Configuration

```json
"commands": {
  "native": "auto",
  "nativeSkills": true,
  "restart": true,
  "ownerDisplay": "raw"
}
```

- `nativeSkills: true` (boolean) — validated working value
- `nativeSkills: "auto"` (string) — caused gateway issues, DO NOT USE

---

## Common Failure Modes

### "No response in Discord"

| Check | Command/Location |
|---|---|
| Gateway running? | `pgrep -x openclaw` |
| Bot in guild? | `curl -H "Authorization: Bot $TOKEN" https://discord.com/api/v10/users/@me/guilds` |
| Channels resolved? | Gateway logs: `grep "discord channels" /tmp/openclaw/openclaw-*.log` |
| Token valid? | `curl -H "Authorization: Bot $TOKEN" https://discord.com/api/v10/users/@me` |
| `visibleReplies` set? | `jq '.messages.groupChat.visibleReplies' ~/.openclaw/openclaw.json` |
| Model errors? | `grep -i "failover\|unknown model" /tmp/openclaw/openclaw-*.log` |

### "Interaction has already been acknowledged"

**Cause:** Two bots with the same token are both connected.

**Fix:** Ensure each environment has a unique `DISCORD_BOT_TOKEN` in GitHub secrets.

### "FailoverError: Unknown model"

**Cause:** `models.mode = "replace"` with empty `models.providers.openrouter.models = []`

**Fix:** Set `models.mode = "merge"` in ideal config. Verify env overrides don't stomp it.

### "Missing API key"

**Cause:** `auth.order` exists but `auth-profiles.json` missing or wrong schema.

**Fix:** Check `scripts/ci/create-auth-profiles.py` ran during deploy. Verify agent dir has `auth-profiles.json` with `"type": "api_key"`.

### "Discord send test returned 400" (health check)

**Cause:** Health check tries to DM the bot itself (`channels/@me/messages`). Some bots can't DM themselves.

**Impact:** Warning only. Does NOT block deploy or actual channel responses.

---

## Recovery Procedures

### Redeploy Single Environment

```bash
# Trigger via GitHub Actions (do NOT ssh and hack)
cd ~/GithubProjects/linux-desktop-seed
gh workflow run deploy.yml --repo DarojaAI/linux-desktop-seed \
  -f action=apply \
  -f environment=test \
  -f skip_apt_update=true \
  -f force=true
```

### Verify Deploy Succeeded

```bash
gh run watch <run-id> --repo DarojaAI/linux-desktop-seed --exit-status
```

### Check Bot Token Race Condition

```bash
# Test VM
curl -s -H "Authorization: Bot $TEST_TOKEN" https://discord.com/api/v10/users/@me | jq '.username, .id'

# Head VM
curl -s -H "Authorization: Bot $HEAD_TOKEN" https://discord.com/api/v10/users/@me | jq '.username, .id'

# Must be DIFFERENT usernames/IDs
```

### Invite Bot to Server

```
https://discord.com/api/oauth2/authorize?client_id=<CLIENT_ID>&permissions=274877910016&scope=bot%20applications.commands
```

Required permissions: Send Messages, Read Message History, Use Slash Commands, View Channels.

---

## Validation Tests

Run before any merge to main:

```bash
# Config merge validation
bats tests/validate-config-merge.bats

# All tests
bats tests/*.bats

# ShellCheck
shellcheck scripts/*.sh scripts/**/*.sh

# Pre-commit
pre-commit run --all-files
```

### What Tests Validate

| Test File | Validates |
|---|---|
| `tests/validate-config-merge.bats` | `models.mode = "merge"`, no env override stomping, `visibleReplies = "automatic"`, no hardcoded channels |
| `tests/model-ids.bats` | Model IDs are valid OpenRouter models |

---

## GitHub Environment Variables/Secrets

### Per-Environment Variables (NOT secrets)

| Variable | Purpose | Example |
|---|---|---|
| `OPENCLAW_DISCORD_GUILD_ID` | Discord server ID | `1485047825967480862` |
| `OPENCLAW_DISCORD_CHANNEL_ID` | Primary channel for this env | `1493278190540427395` |
| `OPENCLAW_DISCORD_ALLOWED_USER` | User ID allowed to interact | `user:1162240440322502656` |
| `OPENCLAW_TARGET_REPOS` | JSON array of repos to bind | `["DarojaAI/dev-nexus", ...]` |

### Per-Environment Secrets

| Secret | Purpose |
|---|---|
| `DISCORD_BOT_TOKEN` | Bot token (ONE per environment) |
| `OPENROUTER_API_KEY` | OpenRouter API key |
| `SSH_PRIVATE_KEY` | SSH key for VM access |

### Repository-Level Secrets (shared across envs)

| Secret | Purpose |
|---|---|
| `HETZNER_API_TOKEN` | Hetzner cloud API |
| `HCX_ACCESS_KEY` / `HCX_SECRET_KEY` | S3 state backend |

---

## File Reference

| File | Purpose | When to Change |
|---|---|---|
| `config/openclaw-ideal-config.json` | Base template | Adding new model aliases, changing auth schema, adding plugins |
| `scripts/ci/generate-openclaw-env-overrides.py` | Env override generator | Adding new env-specific config fields |
| `scripts/merge-openclaw-config.py` | Config merge logic | Changing merge behavior |
| `scripts/ci/create-auth-profiles.py` | Auth credentials generator | Changing auth schema |
| `tests/validate-config-merge.bats` | Config validation tests | Adding new invariant checks |
| `.github/workflows/deploy.yml` | Deploy pipeline | Changing deploy steps |

---

## Change History

| Date | PR | Change |
|---|---|---|
| 2026-05-24 | #454 | Removed ALL hardcoded Discord IDs from ideal config (guild, user, channels) |
| 2026-05-24 | #452 | Changed `models.mode` from `"replace"` to `"merge"` |
| 2026-05-24 | #450 | Fixed env overrides stomping `models.mode` |
| 2026-05-24 | #448 | Reverted broken `ackReactionScope` and `nativeSkills: "auto"` |
| 2026-05-24 | #445 | Fixed `force-deploy` step output reference |
| 2026-05-23 | #443 | Fixed auth schema: `mode` (not `type`) at top-level |
| 2026-05-23 | #442 | Fixed model validation to strip `openrouter/` prefix |
| 2026-05-23 | #440 | Fixed deploy YAML with standalone `create-auth-profiles.py` |
| 2026-05-23 | #435 | Catalog sync fix: only UPDATE existing models |
| 2026-05-23 | #433 | Created validation framework: `test-model-ids.py` + `tests/model-ids.bats` |
| 2026-05-22 | #431 | Reverted model config to original with `openrouter` provider |
| 2026-05-22 | #429 | SSH ControlMaster multiplexing |
