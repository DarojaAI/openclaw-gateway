#!/usr/bin/env bash
set -euo pipefail

# Loop guard shell wrapper
# Usage: loop-guard.sh --source <slug> --target <slug>
#
# Reads agents.lock.toml and checks if target agent should respond.
# Output: JSON {"should_respond": true|false}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/loop-guard.py" "$@"
