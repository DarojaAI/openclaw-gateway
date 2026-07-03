#!/usr/bin/env bash
# scripts/migrate-agent-handles.sh
#
# Shell wrapper for the Python migration script.
# Usage: scripts/migrate-agent-handles.sh [directory] [--json]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/migrate-agent-handles.py"

if [ ! -f "$PYTHON_SCRIPT" ]; then
    echo "ERROR: Python migration script not found: $PYTHON_SCRIPT" >&2
    exit 2
fi

# Default to config/agents if no directory given
AGENT_DIR="${1:-config/agents}"

# Check if directory exists
if [ ! -d "$AGENT_DIR" ]; then
    echo "ERROR: directory not found: $AGENT_DIR" >&2
    exit 2
fi

# Shift off the directory argument, pass remaining flags to Python
if [ $# -gt 0 ]; then
    shift
fi
exec python3 "$PYTHON_SCRIPT" "$AGENT_DIR" "$@"
