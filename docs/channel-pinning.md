# Channel Pinning

Channel pinning enforces that each agent only operates in the Discord channels it declares in its `agent-config.yaml` `allowed_channels` list (RFC #31 Phase 5, Issues #47/#48).

## What it does

When the gateway resolves a routing decision (via `@handle` or `@capability`), it checks whether the originating Discord channel is in the resolved agent's `allowed_channels` list. Two modes:

- **dry-run (default)**: violation logged to stderr as `CHANNEL_PINNING_VIOLATION: ...`, routing decision still emitted on stdout, exit code `0`. Caller can scrape stderr for violations.
- **enforcement**: violation logged to stderr, exit code `4`, no stdout routing decision. Caller (e.g., the Discord bridge) must not proceed with the route.

The caller passes the originating channel via `--channel <snowflake>`. If `--channel` is omitted, no check happens (back-compat for callers that don't have channel context yet).

## Configuration

Per-agent flags in `agent-config.yaml` (and mirrored in `agents.lock.toml`):

| Field | Type | Default | Effect |
|-------|------|---------|--------|
| `dry_run` | bool | **true** | When true, violations are logged but do not block routing |
| `enforce_channel_pinning` | bool | **false** | When true AND `dry_run` is false, violations block routing (exit 4) |

**Default dry-run for one week** per RFC #48. After the dry-run window, flip both flags on the agents you want enforced.

## CLI usage

```bash
# Dry-run mode (default)
scripts/route-by-handle.py --handle @linux-desktop-seed --channel 1501612164098687087
# → exit 0, routing decision with channel_pinning object

# Enforcement mode (per-agent dry_run=false + enforce_channel_pinning=true)
scripts/route-by-handle.py --handle @linux-desktop-seed --channel 999999999999
# → exit 4, no stdout, stderr: CHANNEL_PINNING_VIOLATION: handle=@linux-desktop-seed ...

# Same flags work on capability-dispatch.py
scripts/capability-dispatch.py --capability vm-provision --channel 1501612164098687087
```

## Log format (dry-run violations)

```
CHANNEL_PINNING_VIOLATION: handle=@linux-desktop-seed channel=999999999999 allowed=1501612164098687087 dry_run=True
```

Single-line, stable key=value format. Log scrapers should grep for the `CHANNEL_PINNING_VIOLATION` prefix.

## Exit codes

- `0` — success (route OK OR dry-run violation where decision is emitted)
- `1` — unknown handle or capability
- `2` — lockfile missing or TOML parse error
- `4` — channel pinning violation in enforcement mode (no stdout)

## Migration path

1. Land this PR. All agents default to `dry_run: true, enforce_channel_pinning: false` — no behavior change for existing callers that don't pass `--channel`.
2. Wire the Discord bridge (`discord-claude-bridge.sh` in the seed repo) to pass `--channel <snowflake>` from the message event.
3. Run for one week with all agents in dry-run. Scrape `CHANNEL_PINNING_VIOLATION` lines from gateway logs; investigate any unexpected violations.
4. After one week, opt in to enforcement on each agent individually by setting `dry_run: false` and `enforce_channel_pinning: true` in their `agent-config.yaml`. Each agent's flip is independent.

## Per-agent example

```yaml
# .openclaw/agent-config.yaml
handle: "@linux-desktop-seed"
contract_version: "v1"
allowed_channels:
  - "1492701850217218268"   # #linux-desktop-seed
dry_run: false               # ready for enforcement
enforce_channel_pinning: true # block violations
```
