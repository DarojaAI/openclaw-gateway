# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `schemas/agent-config.schema.json`: canonical JSON Schema (2020-12) for per-agent `.openclaw/agent-config.yaml` files (RFC #31, Phase 1).
- `schemas/agents-lock.schema.json`: JSON Schema for the compiled `agents.lock.toml` lockfile (RFC #31, Phase 1).
- `scripts/validate-agent-config.py`: stdlib-only validator for agent-config.yaml with `--schema` override and dual manual/full validation paths.
- `scripts/generate-agents-lock.py`: emitter that produces the `[agents.<slug>]` TOML entry from a validated agent-config.yaml + repo + config SHA (RFC #31, Phase 1).
- `tests/agent-config-schema.bats`: BATS suite covering schema structure, validator behavior (positive/negative), emitter behavior, and the agents-lock schema (RFC #31, Phase 1).
- `scripts/capability-dispatch.py` + `.sh`: capability-based dispatch (handles when `@handle` lookup misses; `#46`).
- `scripts/_agents_lock.py`: shared TOML parser extracted from the four routing scripts (avoids parser drift).
- `tests/capability-dispatch.bats`: BATS suite for capability-dispatch (17 cases).
- `scripts/channel_pinning.py`: shared channel pinning check (RFC #31 Phase 5, Issues #47/#48). Per-agent `dry_run` (default True) and `enforce_channel_pinning` (default False) flags control whether violations block routing (exit 4) or are only logged.
- `scripts/route-by-handle.py`: `--channel <snowflake>` flag for channel pinning check; emits `channel_pinning` object in the routing decision when channel context is supplied.
- `scripts/capability-dispatch.py`: `--channel <snowflake>` flag for channel pinning check (parity with route-by-handle.py).
- `tests/channel-pinning.bats`: BATS suite (18 cases) covering dry-run default, enforcement mode, multi-channel allowlists, back-compat (no `--channel`), capability-dispatch parity, and module unit checks.
- `schemas/agent-config.schema.json`: new optional fields `dry_run` (default true) and `enforce_channel_pinning` (default false).
- `schemas/agents-lock.schema.json`: same new optional fields, mirrored from the source agent-config schema.
- `config/openclaw-agent-config.example.yaml`: documents the new fields with the default dry-run-for-one-week pattern from RFC #48.
- `config/agents.lock.toml`: every agent entry now declares `dry_run = true` and `enforce_channel_pinning = false` explicitly.
- `scripts/lib-prune-retention.py`: bounded-retention pruner for a target dir (age-and-size caps, oldest-first; dry-run default, `--delete` to apply; issue #134). Wired in as an optional deploy housekeeping step (opt-in via `OPENCLAW_PLUGIN_CAPTURES_RETENTION=1`, deletion additionally gated by `OPENCLAW_PLUGIN_CAPTURES_RETENTION_DELETE=1`; documented in `docs/lifecycle-api.md`). Timer knobs live in `~/.openclaw/plugin-captures-retention.env` (retune without reinstall); pruner holds an exclusive flock on `<target>/.prune-retention.lock` for its scan+delete cycle (coordinates with seed's `prune-openclaw-staging.sh`).
- `.github/workflows/validate.yml`: CI gate running `scripts/merge-openclaw-config.py --validate` on both canonical configs, so the legacy `agents.list` shape cannot return through the template (#133 follow-up).
- `config/openclaw-defaults.json`: per-agent ACP runtime bindings for `daroja_coding_agent`, `darojaai_architect`, `ai_governance` (`agents.entries.*.runtime` with `type=acp`, `agent=opencode`, `backend=acpx`, `mode=persistent`; no `cwd`; issue #118).
- `config/openclaw-defaults.json`: top-level `bindings` array with Discord route entries for the three ACP agents, channel id as the `__OPENCLAW_DISCORD_CHANNEL_ID__` env placeholder (no hardcoded snowflakes; per-env value injected at deploy).
- `docs/tools/acp-agents.md`: multi-agent ACP runtime binding reference (entry shape, ACP mode enum, per-agent OpenRouter auth-profiles sync, Discord channel env-var flow).
- `docs/architecture.md`: per-agent ACP runtime bindings section — documents the per-agent OpenRouter key mechanism actually implemented in `scripts/openrouter-provision.py` (auth-profiles sync; master key never wired into sessions; file/line references) and the Discord channel env-var flow.

### Changed

- `scripts/post-deploy-verify-memory-index.sh`: probe-user resolution falls back to the invoking context's config-file owner (`~/.openclaw/openclaw.json`) when the gateway is down, and refuses to probe as root when unresolvable (rc=2) rather than falsely failing the deploy gate on root's empty store (linux-desktop-seed run 37871548346, step 87). `MEMORY_CHECK_USER` is passed through by `scripts/install/deploy.sh` (default empty = the gate resolves the user itself).
- `scripts/route-by-handle.py`: `route_by_handle()` return shape changed from `dict | None` to `tuple[str, dict] | None` so channel pinning has access to the full agent lockfile entry (allowed_channels, dry_run, enforce_channel_pinning. Output JSON unchanged when `--channel` is not supplied (back-compat.

### Exit codes (RFC #31 Phase 5, #47/#48)

- `0` — success (route + channel OK, OR dry-run violation where decision is still emitted)
- `1` — unknown handle/capability
- `2` — lockfile missing or parse error
- `4` — channel pinning violation in enforcement mode (no stdout routing decision)
