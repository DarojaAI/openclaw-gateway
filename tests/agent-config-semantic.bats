#!/usr/bin/env bats
#
# tests/agent-config-semantic.bats
#
# This file is intentionally empty as of RFC #31 Phase 1.
#
# Prior to Phase 1, this file drove a per-test python+jsonschema
# validator over sample agent-config documents that used `handle_id`
# (UUID v4) and snowflake `allowed_channels`. Those samples do not
# apply to the Phase-1 schema (which uses Discord channel NAMES
# and a handle-based slug). The semantic validator and example
# corpus are reintroduced in a later Phase if and when the agent
# ecosystem is large enough to justify per-case regression coverage.
#
# The Phase-1 semantic coverage is folded into
# `tests/agent-config-schema.bats` (positive + negative cases for
# each field). Pre-commit's `bats-agent-config` hook still runs all
# `tests/agent-config-*.bats` files; this stub contributes zero
# tests so the hook passes.
