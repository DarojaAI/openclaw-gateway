# OpenCLAW Workspace Routing

**Version:** OpenCLAW v2026.04.11 (MiniMax compatible)

Route Discord channels to specific Git repos using a single OpenCLAW instance and a single VS Code window — no matter how many repos you manage.

## The Problem

If you work across multiple repos, the naive setup is one VS Code instance per repo. That works, but each instance uses 2–3 GB of RAM. Three repos means 6–9 GB just for editors.

## The Solution

Run one VS Code window with a multi-root workspace, and configure OpenCLAW **bindings** so that each Discord channel routes to its own repo directory. Every channel behaves independently; only one editor process runs.

```
Discord (1 bot)
    ├── #project-alpha  →  ~/Projects/alpha
    ├── #project-beta   →  ~/Projects/beta
    └── #project-gamma  →  ~/Projects/gamma
```

## Step 1 — Find Your Channel IDs

Channel IDs are Discord snowflakes (17–19 digit numbers). To copy one:

1. Open Discord → Settings → Advanced → turn on **Developer Mode**
2. Right-click a channel → **Copy Channel ID**

Alternatively, open Discord in a browser. The URL looks like:
```
https://discord.com/channels/<guild-id>/<channel-id>
```
The second number is the channel ID.

If you already have sessions in OpenCLAW, you can extract channel IDs from existing files:

```bash
# From the sessions index
grep -o 'discord:[0-9]*#[^"]*' ~/.openclaw/agents/main/sessions/sessions.json | sort -u

# From scheduled jobs
jq '.jobs[].sessionKey' ~/.openclaw/cron/jobs.json

# Broad scan for anything that looks like a snowflake
find /home -name '*.json' -exec grep -l '[0-9]\{17,19\}' {} \; 2>/dev/null
```

## Step 2 — Find Your Repo Paths

```bash
ssh <your-server> "find /home -maxdepth 3 -type d -name '.git' 2>/dev/null"
```

This prints every Git repo root under `/home`, up to three levels deep.

## Step 3 — Configure OpenCLAW Bindings

Edit `~/.openclaw/openclaw.json` and add a `bindings` array. Each entry maps one Discord channel to one workspace directory:

```json
{
  "bindings": [
    {
      "type": "route",
      "agentId": "main",
      "match": {
        "channel": "discord",
        "accountId": "123456789012345678"
      },
      "workspace": "/home/youruser/Projects/alpha",
      "workspaceName": "alpha"
    },
    {
      "type": "route",
      "agentId": "main",
      "match": {
        "channel": "discord",
        "accountId": "987654321098765432"
      },
      "workspace": "/home/youruser/Projects/beta",
      "workspaceName": "beta"
    }
  ]
}
```

Replace the `accountId` values with your real channel IDs, and update the `workspace` paths to match your server.

Then restart the daemon:

```bash
openclaw daemon restart
```

## Step 4 — Set Up a VS Code Multi-Root Workspace

Create a `.code-workspace` file that includes all your repos as folders:

```json
{
  "folders": [
    { "path": "/home/youruser/Projects/alpha" },
    { "path": "/home/youruser/Projects/beta" },
    { "path": "/home/youruser/Projects/gamma" }
  ],
  "settings": {}
}
```

Save it somewhere convenient (e.g., `~/Projects/all.code-workspace`) and open it:

```bash
code ~/Projects/all.code-workspace
```

You can switch between repos using the VS Code Explorer sidebar, or with `/project <name>` if Claude Code is attached to the session.

## Step 5 — Per-Repo API Keys (Optional)

For separate OpenRouter tracking and billing per repository, create a dedicated agent with its own API key.

### Why Per-Repo Keys?

- **Separate tracking** — Each repo shows as its own "app" in OpenRouter analytics
- **Cost attribution** — Know exactly which repo is consuming API credits
- **Key rotation** — Replace a key for one repo without affecting others

### Create a New Repo Agent

```bash
# Set your repo name (used as agent ID)
REPO_NAME="alpha"

# Create agent directory structure
mkdir -p ~/.openclaw/agents/$REPO_NAME/agent
mkdir -p ~/.openclaw/agents/$REPO_NAME/sessions

# Create auth-profiles.json with repo-specific API key
cat > ~/.openclaw/agents/$REPO_NAME/agent/auth-profiles.json << EOF
{
  "version": 1,
  "profiles": {
    "openrouter:default": {
      "type": "api_key",
      "provider": "openrouter",
      "key": "sk-or-v2-YOUR_API_KEY_HERE"
    }
  }
}
EOF
chmod 600 ~/.openclaw/agents/$REPO_NAME/agent/auth-profiles.json
```

### Update Bindings to Use the New Agent

Edit your bindings to reference the new agent:

```json
{
  "bindings": [
    {
      "type": "route",
      "agentId": "alpha",
      "match": {
        "channel": "discord",
        "accountId": "123456789012345678"
      },
      "workspace": "/home/user/Projects/alpha",
      "workspaceName": "alpha"
    }
  ]
}
```

### Restart OpenCLAW

```bash
openclaw daemon restart
```

### Verify the Agent is Active

```bash
# Check agent directories exist
ls -la ~/.openclaw/agents/

# Check auth profile is configured
cat ~/.openclaw/agents/alpha/agent/auth-profiles.json | jq '.profiles'
```

### Using the Script

A convenience script is provided at `scripts/add-openclaw-repo.sh`:

```bash
# Copy to your server
scp scripts/add-openclaw-repo.sh user@server:/tmp/

# Make executable
ssh user@server "chmod +x /tmp/add-openclaw-repo.sh"
```

**Usage:**

```bash
# Minimal (will prompt for channel if not found)
./add-openclaw-repo.sh my-repo -k "sk-or-v2-..."

# Full options
./add-openclaw-repo.sh my-repo -k "sk-or-v2-..." -c "123456789012345678" -p /home/user/Projects/my-repo
```

**What it does:**

1. Creates agent directory: `~/.openclaw/agents/<repo>/agent/`
2. Creates auth-profiles.json with the provided API key
3. Adds binding to map Discord channel → repo workspace
4. Restarts OpenCLAW gateway

**Input handling:**

| Input | Required | Default |
|-------|----------|---------|
| Repo name | Yes | - |
| API key | Yes | - |
| Repo path | No | `~/Projects/<repo-name>` |
| Discord channel | No | Searches existing channels by name, prompts if not found |

**Notes:**

- The script pauses to prompt for channel ID if no matching channel exists
- Requires `jq` to be installed on the server
- Creates minimal agent structure (copies models.json from main agent)

## Troubleshooting

**List active sessions:**
```bash
ls -la ~/.openclaw/agents/main/sessions/
```

**Check which directory a session is using:**
```bash
head -1 ~/.openclaw/agents/main/sessions/<session-id>.jsonl | jq '.cwd'
```

**Verify your bindings were loaded correctly:**
```bash
jq '.bindings' ~/.openclaw/openclaw.json
```

**Stream live logs:**
```bash
tail -f ~/.openclaw/logs/*.log
```

## Memory Impact

| Setup | VS Code instances | Approximate RAM |
|-------|:-----------------:|----------------:|
| One instance per repo (N repos) | N | N × 2–3 GB |
| Multi-root workspace | 1 | 2–3 GB |

For three repos that's roughly a 66–75% reduction in editor memory usage.
