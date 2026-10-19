#!/usr/bin/env bash
# install-gateway-failure-diagnostics.sh — install the gateway start-failure
# diagnostic collector to $HOME/.local/bin (issue #165 consumer mitigation).
#
# Why: the openclaw binary swallows bootstrap exceptions ("The CLI command
# failed."), so crash-loop diagnosis requires the read-only surfaces this
# collector drives (doctor --lint, journal, sidecars, disk). Ship it at a
# stable path so the deploy chain's failure paths and operators can call it
# without hunting.
#
# Honors $HOME so BATS tests can install into a fake home.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIAG_SRC="$REPO_ROOT/scripts/diagnose-gateway-start-failure.py"
DIAG_DST="$HOME/.local/bin/diagnose-gateway-start-failure"

if [[ ! -f "$DIAG_SRC" ]]; then
    echo "ERROR: diagnostic source not found at $DIAG_SRC" >&2
    exit 1
fi

mkdir -p "$(dirname "$DIAG_DST")"
# `install -m 0755` is atomic (rename) — AGENTS.md deploy-snapshot incident.
install -m 0755 "$DIAG_SRC" "$DIAG_DST"
echo "gateway start-failure diagnostic installed to $DIAG_DST"
