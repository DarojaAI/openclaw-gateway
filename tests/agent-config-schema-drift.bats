#!/usr/bin/env bats
#
# tests/agent-config-schema-drift.bats
#
# This file is intentionally empty as of RFC #31 Phase 1.
#
# Prior to Phase 1, this file ran an `openclaw config schema`
# drift-detection test that asserted the committed
# `schemas/agent-config.schema.json` did not match the openclaw
# binary's dumped config schema. That drift story belongs to a
# different schema (the binary's accepted config shape, not the
# per-agent `agent-config.yaml` shape) and is not applicable to
# the Phase-1 schema.
#
# The Phase-1 schema is a hand-written canonical artifact
# (RFC #31), not a derived dump, so a "did it get overwritten by
# the binary dump?" check would be misleading. The drift guard
# is reintroduced as a separate workstream if/when the schema is
# ever generated.
#
# Pre-commit's `bats-agent-config` hook still runs all
# `tests/agent-config-*.bats` files; this stub contributes zero
# tests so the hook passes.
