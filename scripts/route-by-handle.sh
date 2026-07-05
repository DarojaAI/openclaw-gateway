#!/usr/bin/env bash
#
# route-by-handle.sh — Route a Discord @handle to an agent via agents.lock.toml.
#
# Usage:
#   scripts/route-by-handle.sh '@linux-desktop-seed hello'
#   echo '@linux-desktop-seed hello' | scripts/route-by-handle.sh
#   scripts/route-by-handle.sh --handle @linux-desktop-seed
#
# Exit codes:
#   0 — routing decision on stdout (JSON)
#   1 — unknown handle or no handle found
#   2 — TOML parse error or lockfile missing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_SCRIPT="${REPO_ROOT}/scripts/route-by-handle.py"
LOCKFILE="${REPO_ROOT}/config/agents.lock.toml"

# If arguments are passed, pass them through to the Python script.
# If no arguments, pass stdin through.
if [[ $# -gt 0 ]]; then
    exec python3 "${PYTHON_SCRIPT}" --lockfile "${LOCKFILE}" "$@"
else
    exec python3 "${PYTHON_SCRIPT}" --lockfile "${LOCKFILE}"
fi
