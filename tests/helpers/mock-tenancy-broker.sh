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
# "$FIXTURES_DIR/POST_auth_verify.json" — the raw bytes to return for
# POST /auth/verify — plus an optional
# "$FIXTURES_DIR/POST_auth_verify.status" (single integer HTTP status).
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

PORT="${MOCK_PORT:-${1:-18766}}"
FIXTURES_DIR="${MOCK_FIXTURES_DIR:-/tmp/tenancy-mock-$PORT}"
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

exec python3 - "$PORT" "$FIXTURES_DIR" "$REQUESTS_LOG" <<'PY'
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
fixtures = sys.argv[2]
requests_log = sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # silence default stderr access log
        pass

    def _handle(self, method):
        from urllib.parse import urlsplit
        path = urlsplit(self.path).path
        with open(requests_log, "a") as f:
            f.write(f"{method} {self.path}\n")
        norm = path.replace("/", "_")
        body_path = os.path.join(fixtures, f"{method}_{norm}.json")
        status_path = os.path.join(fixtures, f"{method}_{norm}.status")
        status = 200
        body = b'{"triple": null, "valid": false, "exp": null}'
        if os.path.exists(status_path):
            with open(status_path) as f:
                status = int(f.read().strip() or 200)
        if os.path.exists(body_path):
            with open(body_path, "rb") as f:
                body = f.read()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY