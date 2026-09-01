---
name: discord-response-normalizer
description: "Route outbound Discord replies through the normalizer service so model rotation, streaming retries, and stray markdown don't produce inconsistent channel output. Use when an agent's reply is destined for Discord and you want a deterministic 2000-char-chunked, fence-aware, identity-stable message."
---

# Discord Response Normalizer

Single-source-of-truth for "what Discord sees" from any OpenClaw agent on this host. Drop-in module under `/home/desktopuser/.openclaw/services/discord-response-normalizer/discord-normalize.js`.

## When to Use

- Any agent reply destined for Discord (channel message, thread reply, DM).
- Especially when:
  - Multiple model aliases can answer the same prompt (avoid render variance).
  - The reply may exceed 2000 chars (chunking with fence preservation).
  - Streaming retries could re-emit a partial chunk (deterministic identity keeps the bot looking like one agent).

## Quick Start

```javascript
// From any agent workspace:
const normalize = require('/home/desktopuser/.openclaw/services/discord-response-normalizer/discord-normalize');

const result = await normalize.formatReply({
  agent_id: 'linux_desktop_seed',
  text: agentReplyText,
});

// `result.chunks` is an array of <=2000-char strings.
// Each chunk is fence-balanced: if the chunk opens a ``` block,
// the same chunk closes it; cross-chunk fences re-open on the
// next chunk with the matching marker length.
for (const chunk of result.chunks) {
  await discordChannel.send({
    content: chunk,
    username: result.username,        // stable per agent_id
    avatar_url: result.avatar_url,    // stable per agent_id
  });
}
```

## What It Does

1. **Canonicalize** — CRLF→LF, strip trailing whitespace, collapse H4–H6 to `## `, normalize list prefixes (`1)` `1-` `1.` → `1. `), collapse >2 blank lines.
2. **Escape Discord-significant characters outside code fences** — `\`, `*`, `_`, `` ` ``, `~`, `|`, `>` get a leading backslash when they appear mid-prose. Code fences pass through untouched.
3. **Stable identity** — emits `username` and `avatar_url` derived from `agent_id`. Optional `identity_registry` overrides per-agent identity so the same agent looks the same on Discord regardless of which model answered.
4. **Fence-aware chunking** — soft limit 1900 chars, hard cap 2000. Splits at fence boundaries; never splits mid-fence; closes any open fence before a chunk break and re-opens it on the next chunk with the matching marker length.

## CLI

For ad-hoc debugging or batch rewrites:

```bash
echo "raw reply" | /home/desktopuser/.openclaw/services/discord-response-normalizer/normalize-cli.js --agent linux_desktop_seed
```

Pretty-print and file mode:

```bash
node /home/desktopuser/.openclaw/services/discord-response-normalizer/normalize-cli.js \
  --agent linux_desktop_seed \
  --file /tmp/reply.txt \
  --pretty
```

## Identity Registry

Pass an `identity_registry` keyed by `agent_id` when calling `formatReply`:

```javascript
await normalize.formatReply({
  agent_id: 'linux_desktop_seed',
  text: reply,
  identity_registry: {
    linux_desktop_seed: {
      username: 'LDS',
      avatar_url: 'https://example.com/lds-avatar.png',
    },
    darojaai_architect: {
      username: 'Architect',
      avatar_url: 'https://example.com/architect-avatar.png',
    },
  },
});
```

Without a registry entry, the normalizer falls back to a deterministic identity derived from the `agent_id` (DiceBear identicon + `openclaw-<slug>` username) so output is still reproducible across runs.

## Why a Service, Not a Config Block

8.x upstream removed `channels.discord.responsePrefix` (PR #123998). Same upstream posture: fix the agent at the source. This service is the middle path — per-host, opt-in, zero upstream dependency. The drop-in module (`discord-normalize.js`) auto-starts the server on first use, so it's plug-and-play for any agent that requires it.

## Failure Modes

The module is **best-effort by design**. If the normalizer server is down:

- `formatReply()` rejects with the underlying error.
- The caller (your agent) is responsible for falling through to raw `discordChannel.send({ content: text })` — never block on the normalizer.
- This is intentional: a wedged normalizer must not be able to wedge the gateway's outbound path. (Same posture as `viz`: `Wants=` not `PartOf=` in the systemd unit.)

## Implementation Notes

- `lib/normalize.js` is pure functions, no I/O. Unit-tested by `tests/discord-response-normalizer.bats`.
- `normalize-server.js` is a thin Express wrapper. Same logic over HTTP for tests and remote callers.
- `discord-normalize.js` is the agent-side convenience module. Auto-starts the server on first call.
- Constants: `DISCORD_MAX = 2000`, `SOFT_LIMIT = 1900`. Exposed from `lib/normalize.js` so callers and tests share one source of truth.
