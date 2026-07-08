#!/usr/bin/env bash
#
# scripts/openclaw-gateway-audit.sh — Shell wrapper for audit log queries.
#
# Usage:
#     ./scripts/openclaw-gateway-audit.sh [OPTIONS]
#
# Options:
#     --from <agent>       Filter by from_agent slug
#     --to <agent>         Filter by to_agent slug
#     --capability <cap>   Filter by capability
#     --log-path <path>    Path to audit log (default: ~/.local/log/openclaw-audit.log)
#
# Exit codes:
#   0  — success
#   1  — invalid arguments

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"

if [ $# -eq 0 ]; then
    echo "Usage: openclaw-gateway-audit.sh [--from <agent>] [--to <agent>] [--capability <cap>] [--log-path <path>]" >&2
    exit 1
fi

exec "$PYTHON" "${SCRIPT_DIR}/audit_log.py" query "$@"
