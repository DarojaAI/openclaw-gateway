#!/usr/bin/env bash
# Local pre-commit hook helper: runs the agent-config BATS suites against
# staged changes. Skips gracefully when bats or python deps are missing
# (CI catches those cases). Exits 0 if no relevant files are staged.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Skip if nothing agent-config-related is staged.
if ! compgen -G "tests/agent-config-*.bats" "${REPO_ROOT}" > /dev/null \
   && [ ! -f "${REPO_ROOT}/schemas/agent-config.schema.json" ] \
   && [ ! -f "${REPO_ROOT}/config/openclaw-agent-config.example.yaml" ] \
   && [ ! -f "${REPO_ROOT}/config/openclaw-version" ]; then
	echo "No agent-config files staged; skipping."
	exit 0
fi

# Skip if bats is not installed locally (CI will run it).
if ! command -v bats >/dev/null 2>&1; then
	echo "bats not installed; skipping locally (CI will catch)."
	exit 0
fi

# Skip if jsonschema/pyyaml missing (semantic suite needs them).
if ! python3 -c "import jsonschema, yaml" 2>/dev/null; then
	echo "jsonschema/pyyaml not installed; skipping locally (CI will catch)."
	exit 0
fi

cd "${REPO_ROOT}"
bats tests/agent-config-schema.bats tests/agent-config-semantic.bats tests/agent-config-schema-drift.bats