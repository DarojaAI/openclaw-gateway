#!/usr/bin/env bash
#
# load-agents-lock.sh — Wrapper to load agents.lock.toml and log the result.
#
# Usage:
#   scripts/install/openclaw/load-agents-lock.sh [path/to/agents.lock.toml]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PYTHON_SCRIPT="${REPO_ROOT}/scripts/load-agents-lock.py"

LOCKFILE="${1:-${REPO_ROOT}/config/agents.lock.toml}"

if [[ ! -f "${LOCKFILE}" ]]; then
  echo "Loaded 0 agents from agents.lock.toml (file not found)"
  exit 0
fi

# Run the Python loader and capture JSON
JSON_OUTPUT="$(python3 "${PYTHON_SCRIPT}" "${LOCKFILE}")"

# Count agents from the JSON output (agents is a dict; count its keys)
AGENT_COUNT="$(python3 -c "import json, sys; d = json.loads(sys.stdin.read()); print(len(d.get('agents', {})))" <<< "${JSON_OUTPUT}")"

echo "Loaded ${AGENT_COUNT} agents from agents.lock.toml"

# Also output the JSON so the caller can consume it
echo "${JSON_OUTPUT}"
