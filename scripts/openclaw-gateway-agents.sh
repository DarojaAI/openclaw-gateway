#!/usr/bin/env bash
#
# openclaw-gateway-agents.sh — List agents from agents.lock.toml.
#
# Usage:
#   scripts/openclaw-gateway-agents.sh [path/to/agents.lock.toml]
#
# Exit codes:
#   0 — success (table on stdout)
#   2 — parse error
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_SCRIPT="${REPO_ROOT}/scripts/openclaw-gateway-agents.py"

LOCKFILE="${1:-${REPO_ROOT}/config/agents.lock.toml}"

exec python3 "${PYTHON_SCRIPT}" "${LOCKFILE}"
