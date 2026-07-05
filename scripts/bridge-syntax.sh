#!/usr/bin/env bash
#
# scripts/bridge-syntax.sh — Shell wrapper for bridge-syntax.py
#
# Usage:
#     ./scripts/bridge-syntax.sh <message> [path/to/agents.lock.toml]
#
# Exit codes:
#   0  — success (JSON routing decision on stdout)
#   1  — malformed syntax or unknown agent
#   2  — lockfile missing or parse error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"

if [ $# -lt 1 ]; then
    echo "Usage: bridge-syntax.sh <message> [path/to/agents.lock.toml]" >&2
    exit 1
fi

exec "$PYTHON" "${SCRIPT_DIR}/bridge-syntax.py" "$@"
