# Bridge Syntax

Quick reference for agent-to-agent communication via bridge syntax (RFC #31 Phase 4).

## What is bridge syntax?

Bridge syntax lets an operator (human or operator-initiated agent) route a message from one agent to another using a `@A ask @B <question>` pattern. The gateway parses the message, resolves both agents from `config/agents.lock.toml`, and emits a JSON routing decision.

```
@linux-desktop-seed ask @darojaai-architect What is the current architecture of the gateway?
```

## Usage

### Shell wrapper

```bash
# Basic usage — JSON routing decision on stdout
./scripts/bridge-syntax.sh "@linux-desktop-seed ask @darojaai-architect What is the current architecture?"

# Custom lockfile path
./scripts/bridge-syntax.sh "@linux-desktop-seed ask @darojaai-architect What is the current architecture?" /path/to/agents.lock.toml
```

### Python directly

```bash
python3 scripts/bridge-syntax.py "@linux-desktop-seed ask @darojaai-architect What is the current architecture?"
```

### Example output

```json
{
  "source_agent": {
    "handle": "@linux-desktop-seed",
    "slug": "linux-desktop-seed",
    "repo": "DarojaAI/linux-desktop-seed"
  },
  "target_agent": {
    "handle": "@darojaai-architect",
    "slug": "darojaai-architect",
    "repo": "DarojaAI/darojaai-architect"
  },
  "question": "What is the current architecture of the gateway?",
  "bridge_syntax": "@linux-desktop-seed ask @darojaai-architect What is the current architecture of the gateway?"
}
```

## Syntax format

```
@<source-handle> ask @<target-handle> <question>
```

- `@<source-handle>` — the agent initiating the request (Discord @mention format)
- `ask` — keyword; must be exactly `ask`
- `@<target-handle>` — the agent being asked
- `<question>` — everything after the target handle

Handles use hyphenated slugs (e.g. `@linux-desktop-seed`, `@darojaai-architect`). They match the `handle` field in `config/agents.lock.toml`.

## Configuration

### Lockfile: `config/agents.lock.toml`

Each agent entry has a `handle` field and optional `loop_guard` setting:

```toml
[agents.linux-desktop-seed]
repo             = "DarojaAI/linux-desktop-seed"
handle           = "@linux-desktop-seed"
contract_version = "v1"
config_source    = "https://..."
config_sha       = "..."
loop_guard       = true

[agents.darojaai-architect]
repo             = "DarojaAI/darojaai-architect"
handle           = "@darojaai-architect"
contract_version = "v1"
config_source    = "https://..."
config_sha       = "..."
loop_guard       = true
```

### Loop guard per agent

The `loop_guard` field controls whether an agent can respond to another agent's bridge syntax request:

| `loop_guard` value | Behavior |
|--------------------|----------|
| `true` (default) | Agent **cannot** respond to other agents (loop prevention) |
| `false` | Agent **can** respond to other agents |

**Default:** if `loop_guard` is not set, the agent cannot respond (guard ON). This is the safe default — agents do not auto-respond to each other unless explicitly opted in.

### Setting loop guard

In `config/agents.lock.toml`, set `loop_guard = false` on the agent that should be allowed to respond:

```toml
[agents.darojaai-architect]
repo             = "DarojaAI/darojaai-architect"
handle           = "@darojaai-architect"
loop_guard       = false   # allows this agent to respond to bridge requests
```

## How routing works

1. **Parse**: The gateway extracts `@source ask @target <question>` from the message.
2. **Load lockfile**: `config/agents.lock.toml` is loaded into memory.
3. **Resolve both agents**: The source and target handles are looked up in the lockfile's `agents` section.
4. **Check loop guard**: If the target agent has `loop_guard: true`, the response is blocked (unless explicitly opted in with `loop_guard: false`).
5. **Emit**: A JSON routing decision is emitted with source agent info, target agent info, and the question.

## Error handling

### Unknown agent

If a handle is not found in the lockfile:

```
ERROR: unknown agent '@unknown-agent' in lockfile /path/to/agents.lock.toml
```

**Fix:** Ensure the agent is listed in `config/agents.lock.toml` with a valid `handle` field.

### Missing lockfile

If the lockfile doesn't exist or is empty:

```
ERROR: lockfile not found or empty: /path/to/agents.lock.toml
```

**Fix:** Run `generate-agents-lock.py` to generate the lockfile, or ensure `config/agents.lock.toml` exists.

### Malformed syntax

If the message doesn't match `@A ask @B <question>`:

```
ERROR: malformed bridge syntax: expected @A ask @B <question>, got '@linux-desktop-seed hello'
```

**Fix:** Use exactly the `@source ask @target <question>` format.

### TOML parse error

If the lockfile has invalid TOML syntax:

```
ERROR: TOML parse error in /path/to/agents.lock.toml: <error>
```

**Fix:** Check the lockfile for syntax errors (missing quotes, invalid sections, etc.).

## Limitations

1. **Operator-initiated only**: Bridge syntax is designed for human operators to route messages between agents. It is not an automatic agent-to-agent protocol.
2. **Loop guard**: By default, agents cannot respond to each other. This prevents infinite loops where agents keep asking each other questions. Only agents with `loop_guard: false` can respond.
3. **Single target**: Each bridge syntax message routes to exactly one target agent. You cannot broadcast to multiple agents in a single request.
4. **No payload format**: The question is a free-form string. There is no structured payload — it's just text.
5. **Lockfile dependency**: Routing requires `config/agents.lock.toml` to be present and up-to-date. Stale lockfiles will cause routing failures.

## See also

- `scripts/loop-guard.py` — Loop guard check for agent-to-agent responses
- `scripts/route-by-handle.py` — Route a single `@handle` mention to its agent
- `scripts/bridge-syntax.sh` — Shell wrapper for bridge syntax parser
- `tests/bridge-syntax.bats` — BATS tests for bridge syntax
