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
