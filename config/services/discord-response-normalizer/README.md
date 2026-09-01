# OpenClaw Discord Response Normalizer

Single source of truth for what Discord sees from every OpenClaw agent on this host. Sits between the agent's text output and the Discord send path so model-alias rotation, agent handoff, streaming retries, and stray markdown characters don't leak into user-visible channel output as inconsistent formatting.

## Location

`/home/desktopuser/.openclaw/services/discord-response-normalizer/`

## Architecture

```
┌─────────────────┐    HTTP POST /normalize    ┌──────────────────────┐
│  Any OpenClaw   │ ──────────────────────────>│  normalize-server    │
│  agent          │  {agent_id, text,          │  (Express)           │
│                 │   identity_registry?}      │  Port 8767           │
│                 │ <──────────────────────────│                      │
│                 │  {chunks, username,        │  Pure logic in       │
│                 │   avatar_url, content}     │  lib/normalize.js    │
└─────────────────┘                            └──────────────────────┘
```

## Components

| File | Purpose |
|------|---------|
| `normalize-server.js` | Express server, `POST /normalize` + `GET /health` |
| `normalize-cli.js` | CLI: `node normalize-cli.js --agent <id>` reads stdin, emits JSON |
| `discord-normalize.js` | Node module — auto-starts server, calls `/normalize`, returns the same shape as `services/viz/discord-viz.js` |
| `lib/normalize.js` | Pure-function core: canonicalize, escape, chunk, identity |

## Pipeline

1. **Canonicalize** — CRLF → LF, strip trailing whitespace, collapse deep headings (H4–H6) to `## `, normalize numbered list prefixes (`1) ` / `1- ` → `1. `), collapse runs of >2 blank lines.
2. **Escape Discord-significant characters outside code fences** — backslash-escape `\`, `*`, `_`, `` ` ``, `~`, `|`, `>` when they appear in prose. Inside fenced code blocks (3+ backticks), characters pass through untouched.
3. **Deterministic identity block** — emit `username` + `avatar_url` derived from `agent_id`. Optional `identity_registry` overrides per-agent identity so the same agent always looks the same on Discord regardless of which model answered.
4. **Fence-aware chunking** — split at the soft limit (1900 chars) but always at fence boundaries. Closing fence on chunk N, opening fence on chunk N+1 (matching marker length) so Discord never sees an unterminated code block. Hard cap 2000 chars per chunk.

## Usage

### From any agent

```javascript
const normalize = require('/home/desktopuser/.openclaw/services/discord-response-normalizer/discord-normalize');
const result = await normalize.formatReply({
  agent_id: 'linux_desktop_seed',
  text: agentReplyText,
});
for (const chunk of result.chunks) {
  await discordChannel.send({
    content: chunk,
    username: result.username,
    avatar_url: result.avatar_url,
  });
}
```

### CLI

```bash
# From stdin
echo "raw reply" | node /home/desktopuser/.openclaw/services/discord-response-normalizer/normalize-cli.js --agent linux_desktop_seed

# From a file
node /home/desktopuser/.openclaw/services/discord-response-normalizer/normalize-cli.js --agent linux_desktop_seed --file /tmp/reply.txt

# Pretty-printed JSON
node /home/desktopuser/.openclaw/services/discord-response-normalizer/normalize-cli.js --agent linux_desktop_seed --pretty
```

### HTTP API

```bash
curl -s http://localhost:8767/health
# {"status":"ok","service":"discord-response-normalizer","version":"0.1.0"}

curl -s -X POST http://localhost:8767/normalize \
  -H 'Content-Type: application/json' \
  -d '{"agent_id":"linux_desktop_seed","text":"use the _foo_ flag\n```\ncode block here\n```"}'
```

## Environment Variables

| Var | Default | Description |
|-----|---------|-------------|
| `NORMALIZER_PORT` | `8767` | Server port |
| `NORMALIZER_HOST` | `localhost` | Server hostname |
| `NORMALIZER_CACHE_DIR` | `./cache` | Reserved for future deterministic-avatar caching |

## Skill Registration

The skill is registered at `/home/desktopuser/.openclaw/skills/discord-response-normalizer/SKILL.md` so all OpenClaw agents discover it.

## Setup / Reinstall

```bash
cd /home/desktopuser/.openclaw/services/discord-response-normalizer
npm install
node normalize-server.js &
```

Or via the gateway installer (recommended for fresh deploys):

```bash
bash /home/desktopuser/.openclaw/openclaw-gateway/scripts/services/install-discord-response-normalizer-service.sh
```

The installer will:

- Copy service files to `~/.openclaw/services/discord-response-normalizer/`
- Copy the skill to `~/.openclaw/skills/discord-response-normalizer/SKILL.md`
- Symlink the systemd unit from `etc/systemd/user/openclaw-discord-response-normalizer.service` into `~/.config/systemd/user/`
- Enable and start the service

## Service Management

```bash
systemctl --user status openclaw-discord-response-normalizer
systemctl --user restart openclaw-discord-response-normalizer
journalctl --user -u openclaw-discord-response-normalizer -f
```

The service is intentionally **not** wired into the gateway lifecycle with `Before=` or `PartOf=`. (See `etc/systemd/user/openclaw-viz.service` for the 2026-06-09 post-mortem on why `PartOf=` is the wrong directive for "I want to start with the gateway.") The normalizer is best-effort: if it's down, the gateway falls through and sends un-normalized output, which is strictly better than refusing to send.

## Why "best-effort, not PartOf=?"

The gateway must never be unable to send a Discord reply because the normalizer is down. A single hung normalize-server process would otherwise wedge every agent that has Discord as a delivery surface. The drop-in module (`discord-normalize.js`) auto-starts the server on first use, so the service only needs to be enabled once at install time.

## Bot Access

This service is accessible to ALL OpenClaw agents on this host — same as `viz`. Each agent can `require()` the module and route outbound Discord replies through it independently.

## Why not a `post-processor` config block?

8.x upstream removed `channels.discord.responsePrefix` (PR #123998) — same upstream posture: fix the agent at the source, not the wire. This service is the *middle* option: a per-host, zero-config-on-7.x, opt-in shim that doesn't require upstream schema changes and works regardless of what model answered.
