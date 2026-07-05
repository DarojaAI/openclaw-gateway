#!/usr/bin/env bash
#
# capability-dispatch.sh — Capability-based dispatch for Discord messages.
#
# Usage:
#   scripts/capability-dispatch.sh --message '@vm-provision hello'
#   scripts/capability-dispatch.sh --capability vm-provision
#   scripts/capability-dispatch.sh --handle @linux-desktop-seed
#   echo '@vm-provision hello' | scripts/capability-dispatch.sh
#
# Exit codes:
#   0 — routing decision on stdout (JSON)
#   1 — unknown handle/capability or none found
#   2 — TOML parse error or lockfile missing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
exec python3 "${REPO_ROOT}/scripts/capability-dispatch.py" --lockfile "${REPO_ROOT}/config/agents.lock.toml" "$@"
