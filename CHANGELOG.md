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

### Changed

- `scripts/route-by-handle.py`: `route_by_handle()` return shape changed from `dict | None` to `tuple[str, dict] | None` so channel pinning has access to the full agent lockfile entry (allowed_channels, dry_run, enforce_channel_pinning). Output JSON unchanged when `--channel` is not supplied (back-compat).

### Exit codes (RFC #31 Phase 5, #47/#48)

- `0` — success (route + channel OK, OR dry-run violation where decision is still emitted)
- `1` — unknown handle/capability
- `2` — lockfile missing or parse error
- `4` — channel pinning violation in enforcement mode (no stdout routing decision)
