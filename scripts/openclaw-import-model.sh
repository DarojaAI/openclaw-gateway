#!/usr/bin/env bash
# OpenRouter Model Import Wrapper for OpenClaw
#
# Thin wrapper around scripts/openclaw-import-model.py that validates
# prerequisites and provides friendly error messages.
#
# Usage:
#   ./scripts/openclaw-import-model.sh --model-id tencent/hy3-preview:free --alias frida --force
#   ./scripts/openclaw-import-model.sh --model-id google/gemini-2.5-pro --alias gemini --set-default --dry-run
#
# All arguments are passed through to the Python script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/openclaw-import-model.py"

# Logging helpers
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# Find Python executable (python3 preferred, fallback to python)
find_python() {
	if command -v python3 &>/dev/null; then
		echo "python3"
	elif command -v python &>/dev/null; then
		echo "python"
	else
		log_error "Python is required but not installed (tried python3, python)."
		exit 1
	fi
}

# Validate prerequisites
check_prerequisites() {
	PYTHON_CMD="$(find_python)"

	if [[ ! -f "$PYTHON_SCRIPT" ]]; then
		log_error "Python script not found: $PYTHON_SCRIPT"
		exit 1
	fi
}

main() {
	check_prerequisites

	log_info "Running OpenRouter model import..."

	if "$PYTHON_CMD" "$PYTHON_SCRIPT" "$@"; then
		log_info "Import completed successfully."
	else
		exit_code=$?
		log_error "Import failed with exit code $exit_code."
		exit "$exit_code"
	fi
}

main "$@"
