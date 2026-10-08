#!/bin/bash
# tests/helpers/mock-tenancy-broker.sh
#
# Tiny stand-in for the daroja-tenancy round-2 broker's /auth/verify
# endpoint, used by tests/preflight-gate.bats (P1 tenant-model checks).
# Serves canned responses from a fixtures directory, mirroring
# tests/helpers/mock-openrouter.sh.
#
# Fixture layout
# --------------
# The test points TENANCY_BROKER_URL at the mock and creates
# "$FIXTURES_DIR/POST_verify.json" — the raw bytes to return for
# POST /auth/verify — plus an optional
# "$FIXTURES_DIR/POST_verify.status" (single integer HTTP status).
# The round-2 contract returns {"triple": {...}, "valid": bool, "exp": n}.
# Every request is recorded into "$FIXTURES_DIR/requests.log"
# (one line per request: METHOD PATH).
#
# Why a python server (not bash -c 'nc -l')
# -----------------------------------------
# http.server gives us method-routed fixtures + a request log with no
# third-party deps; the bash wrapper handles port selection, stdout
# port-print, and clean shutdown. Same design as mock-openrouter.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PORT="${MOCK_PORT:-${1:-18766}}"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
REQUESTS_LOG="$FIXTURES_DIR/requests.log"

mkdir -p "$FIXTURES_DIR"
: > "$REQUESTS_LOG"

# Refuse to start if the port is already in use.
if (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
	echo "mock-tenancy-broker: port $PORT is already in use" >&2
	exit 1
fi

# Print the port first so the parent test can capture it even if
# the python server fails to bind.
echo "$PORT"

exec python3 "$SCRIPT_DIR/mock-tenancy-broker_impl.py" "$PORT"
