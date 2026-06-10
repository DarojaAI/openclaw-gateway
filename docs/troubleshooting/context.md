# OpenCLAW Context Management Troubleshooting Log

**OpenCLAW Version:** v2026.04.11 (MiniMax compatible)
**Last Updated:** 2026-04-13
**Purpose:** Document context management issues and fixes for future reference

---

## Errors Encountered

### Error 1: Compaction Failed (233k tokens)
```
⚙️ Compaction failed: Summarization failed: 400
This endpoint's maximum context length is 204800 tokens.
However, you requested about 233412 tokens (169412 of text input, 64000 in the output).
Please reduce the length of either one, or use the context-compression plugin.
```

**Root Cause:** High token reserves (140k-200k) consumed all headroom. When compaction tried to run, there wasn't enough free space to perform compression. The system couldn't compress because it was already too full.

### Error 2: Context Limit Exceeded
```
Context limit exceeded. I've reset our conversation to start fresh - please try again.
To prevent this, increase your compaction buffer by setting agents.defaults.compaction.reserveTokensFloor to 20000 or higher in your config.
```

**Root Cause:** Compaction couldn't run due to Error 1, hitting the hard context limit.

### Error 3: Cost Issue
**Symptom:** Regular requests sending 80k-100k+ tokens
**Root Cause:** `maxHistoryShare: 0.3` (30%) allowed too much history retention

---

## Configuration Changes Applied

### Initial (Problematic) Settings
```json
{
  "compaction": {
    "reserveTokens": 140000,
    "reserveTokensFloor": 100000,
    "maxHistoryShare": 0.3,
    "keepRecentTokens": 8000
  }
}
```

### Final (Fixed) Settings
```json
{
  "compaction": {
    "mode": "default",
    "reserveTokens": 20000,
    "reserveTokensFloor": 20000,
    "maxHistoryShare": 0.1,
    "keepRecentTokens": 4000
  }
}
```

> **Note:** `maxHistoryShare` minimum is 0.1. Values below 0.1 are rejected by the gateway.

---

## Key Insights

1. **Higher reserves caused the problem, not solved it.** The error message "increase buffer" was misleading for this case. High reserves (140k-200k) consumed the headroom needed for compression to work.

2. **Compaction needs free space to run.** Think of reserves as "working room" for compression, not as a safety buffer.

3. **The tradeoff:**
   - Too little reserve → context reset (no buffer)
   - Too much reserve → compaction fails (no working room)
   - 20k reserve on 1M context = 2% = plenty of buffer AND working room

4. **maxHistoryShare controls cost.** 30% (300k) was too much. 10% (100k) is the cap.

---

## Testing Results

| Metric | Before | After |
|--------|--------|-------|
| Compaction failures | Yes | No |
| Context resets | Yes | No |
| Tokens per request | 80-100k | 20-40k average |
| Max history | 300k | 100k |

---

## Future Troubleshooting

### If context resets happen again:
- Increase reserveTokens by 5k-10k chunks
- Try: reserveTokens: 25000, reserveTokensFloor: 25000

### If compaction fails again:
- Reduce reserveTokens (not increase)
- The error message is misleading - more reserves = worse problem

### If cost is still too high:
- Lower maxHistoryShare: 0.05 (5% = 50k max)
- Or lower keepRecentTokens: 2000

### To verify running config on VM:
```bash
ssh hetzner "jq '.agents.defaults.compaction' ~/.openclaw/openclaw.json"
```

### To update VM config:
```bash
# For manual compaction fix (use Haiku for summarization):
ssh prod "jq '.agents.defaults.compaction += {\"model\": \"openrouter/anthropic/claude-haiku-4-5\", \"mode\": \"safeguard\"} | .agents.defaults.compaction.reserveTokens = 15000' /home/desktopuser/.openclaw/openclaw.json > /tmp/openclaw.json && cp /tmp/openclaw.json /home/desktopuser/.openclaw/openclaw.json"
```

---

## Related Files

- `config/openclaw-defaults.json` - Repository defaults (should match working VM config)
- `~/.openclaw/openclaw.json` - Running config on VM (hetzner)

---

## Discord Integration Issues (2026-04-08)

### Problem
Discord messages to intelligent-feed channel (DISCORD_CHANNEL_ID_PLACEHOLDER) not being received/processed by OpenCLAW gateway.

### Errors Encountered

1. **Config validation failures**
   - Minimal configs kept failing validation
   - Missing required fields: `models.providers.openrouter.baseUrl`, `apiKey`, `models`
   - "bindings.0: Invalid input"

2. **Root config conflict**
   - Running `openclaw` commands as root created `/root/.openclaw/openclaw.json`
   - Gateway restart checked root's config, not desktopuser's
   - Root config had invalid format causing all restarts to fail

3. **Gateway status misleading**
   - `openclaw gateway status` showed "stopped" even when running
   - RPC probe failed but HTTP server was responding on port 18789
   - Systemd service kept restarting/terminating gateway

### Solution Applied

1. Removed root config: `rm /root/.openclaw/openclaw.json`
2. Restored working config from April 2 backup (`openclaw.json.bak.4`)
3. Updated Discord token to current valid token
4. Added bindings for channel routing:
   ```json
   "bindings": [
     {
       "agentId": "main",
       "match": {
         "channel": "discord",
         "accountId": "DISCORD_ACCOUNT_ID_PLACEHOLDER"
       }
     }
   ]
   ```
5. Disabled systemd service and ran gateway directly

### deploy-desktop.sh Fix
Updated wrapper to use desktopuser's config path instead of `$HOME`:
```bash
# Before (broken)
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"

# After (fixed)
OPENCLAW_CONFIG="/home/desktopuser/.openclaw/openclaw.json"
```

Also fixed `setup_openclaw_config()` function to use:
```bash
OPENCLAW_CONFIG_DIR="/home/desktopuser/.openclaw"
```

### Key Takeaways

1. **Never run openclaw commands as root** - Creates conflicting config
2. **Restore from known-working backup** - Config format validation is strict; old working config is safer than minimal new ones
3. **Verify gateway is actually running** - Check port 18789 response, not just `gateway status`
4. **Systemd can cause instability** - Running gateway directly without systemd service is more reliable

### Working Config Structure
```json
{
  "meta": { "lastTouchedVersion": "2026.04.11" },
  "channels": {
    "discord": {
      "enabled": true,
      "token": "DISCORD_BOT_TOKEN_PLACEHOLDER",
      "groupPolicy": "allowlist",
      "allowFrom": ["user:DISCORD_USER_ID_PLACEHOLDER"],
      "guilds": {
        "DISCORD_GUILD_ID_PLACEHOLDER": {
          "requireMention": false,
          "users": ["DISCORD_USER_ID_PLACEHOLDER"]
        }
      }
    }
  },
  "bindings": [
    {
      "agentId": "main",
      "match": {
        "channel": "discord",
        "accountId": "DISCORD_ACCOUNT_ID_PLACEHOLDER"
      }
    }
  ],
  "agents": {
    "defaults": {
      "model": { "primary": "openrouter/minimax/minimax-m2.7" }
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "auth": { "mode": "token", "token": "..." }
  }
}
```

---

## Manual Compaction Fix (2026-04-13)

### Problem
`/compact` command failed in dev-nexus channel with error:
```
⚙️ Compaction failed: Turn prefix summarization failed: 400
Reasoning is mandatory for this endpoint and cannot be disabled.
```

- Context was at 67% (67k/100k)
- Worked in other channels (smaller context)
- Failed in dev-nexus because compaction triggered on large context

### Root Cause
MiniMax model was being used for summarization during compaction. The API call was either disabling reasoning or not properly enabling it, causing the request to fail.

### Solution Applied
1. Added dedicated compaction model: `openrouter/anthropic/claude-haiku-4-5-20251001`
2. Changed mode from `default` to `safeguard` (chunked summarization)
3. Reduced `reserveTokens` from 20000 to 15000

**Final Working Config:**
```json
{
  "compaction": {
    "mode": "safeguard",
    "model": "openrouter/anthropic/claude-haiku-4-5",
    "reserveTokens": 15000,
    "keepRecentTokens": 4000,
    "reserveTokensFloor": 20000,
    "maxHistoryShare": 0.1
  }
}
```

### Key Insight
Use a separate, cheaper model (Haiku) for compaction summarization instead of the main session model (MiniMax). This avoids reasoning compatibility issues and reduces cost. **Important:** Use the `openrouter/anthropic/claude-haiku-4-5` format - not `anthropic/claude-haiku-4.5` or other variants.

### To Apply This Fix
```bash
ssh prod "jq '.agents.defaults.compaction += {\"model\": \"openrouter/anthropic/claude-haiku-4-5\", \"mode\": \"safeguard\"} | .agents.defaults.compaction.reserveTokens = 15000' /home/desktopuser/.openclaw/openclaw.json > /tmp/openclaw.json && cp /tmp/openclaw.json /home/desktopuser/.openclaw/openclaw.json"
```

---

## Appendix: Emergency Troubleshooting Card

> **When Discord bot stops responding, work through this checklist IN ORDER.**
> **Do NOT skip steps. Do NOT ssh and hack. Use the deploy pipeline.**

### Step 1: Identify Which Environment is Broken

```bash
cd ~/GithubProjects/linux-desktop-seed
gh run list --repo DarojaAI/linux-desktop-seed --workflow=deploy.yml --limit 5
```

### Step 2: Check Bot Token Validity (No SSH Needed)

```bash
curl -s -H "Authorization: Bot <TOKEN>" https://discord.com/api/v10/users/@me | jq '{name: .username, id: .id}'
```

**Expected:** Returns bot name and ID.
**If 401:** Token invalid → regenerate in Discord Developer Portal → update GitHub secret → redeploy.

### Step 3: Check Bot is in Guild

```bash
curl -s -H "Authorization: Bot <TOKEN>" https://discord.com/api/v10/users/@me/guilds | jq 'length'
```

**Expected:** >= 1 guilds.
**If 0:** Bot was kicked → re-invite via `https://discord.com/api/oauth2/authorize?client_id=<CLIENT_ID>&permissions=274877910016&scope=bot%20applications.commands`

### Step 4: Check for Token Race Condition

```bash
# If both test and head bots return the same username, they're sharing a token
curl -s -H "Authorization: Bot <TEST_TOKEN>"  https://discord.com/api/v10/users/@me | jq '.username'
curl -s -H "Authorization: Bot <HEAD_TOKEN>"  https://discord.com/api/v10/users/@me | jq '.username'
```

**If SAME username:** Both envs share a token → update one in GitHub secrets → redeploy.

### Step 5: Check Gateway is Running (SSH Required)

```bash
ssh -i <key> <user>@<IP> "pgrep -x openclaw && echo 'running' || echo 'NOT running'"
```

**If NOT running:** Trigger redeploy. Do NOT start manually.

### Step 6: Check Gateway Logs for Errors

```bash
ssh -i <key> <user>@<IP> "sudo -u desktopuser grep -iE 'error|fail|unknown model|missing api key' /tmp/openclaw/openclaw-*.log | tail -10"
```

| Error Pattern | Meaning | Fix |
|---|---|---|
| `FailoverError: Unknown model` | `models.mode` wrong or empty catalog | Verify `models.mode = "merge"` in ideal config |
| `Missing API key` | Auth profiles missing | Check `create-auth-profiles.py` ran during deploy |
| `Interaction has already been acknowledged` | Token race condition | Different tokens per env |
| `discord channels unresolved` | Bot can't see channel | Check bot invited + permissions |

### Step 7: Verify Config on VM

```bash
ssh -i <key> <user>@<IP> "sudo -u desktopuser python3 -c '
import json
c = json.load(open(\"/home/desktopuser/.openclaw/openclaw.json\"))
print("mode:", c["models"]["mode"])
print("visibleReplies:", c["messages"]["groupChat"]["visibleReplies"])
print("channels:", list(c["channels"]["discord"]["guilds"].values())[0]["channels"].keys())
print("token prefix:", c["channels"]["discord"]["token"][:20])
'"
```

**Expected:** `mode: merge`, `visibleReplies: automatic`, only one channel per env, token matches expected bot.

### Step 8: Redeploy (The Fix for 90% of Issues)

```bash
cd ~/GithubProjects/linux-desktop-seed
gh workflow run deploy.yml --repo DarojaAI/linux-desktop-seed \
  -f action=apply -f environment=<test|head|prod> -f skip_apt_update=true -f force=true
gh run watch $(gh run list --repo DarojaAI/linux-desktop-seed --workflow=deploy.yml --limit 1 --json id --jq '.[0].id')
```

### Common Mistakes

1. **Hardcoding channel/guild/user IDs in `openclaw-ideal-config.json`** → Use GitHub env vars.
2. **`models.mode = "replace"` with empty `models` array** → Use `"merge"`.
3. **Sharing bot tokens across environments** → One token per environment.
4. **Editing `openclaw.json` directly on VM** → Change lost on next deploy.
5. **Forgetting to re-invite bot after token reset** → Re-invite via OAuth URL.
