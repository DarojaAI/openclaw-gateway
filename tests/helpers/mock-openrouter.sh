#!/bin/bash
# tests/helpers/mock-openrouter.sh
#
# Tiny stand-in for the OpenRouter provisioning API, used by
# tests/openrouter-provision.bats. Listens on a localhost port and
# serves canned responses from a fixtures directory chosen by
# HTTP method and URL path. The port is printed on stdout so the
# test can capture it and point OPENROUTER_API_BASE at the mock.
#
# Fixture layout
# --------------
# The test creates a temporary dir with one file per response,
# named "<METHOD>_<PATH_WITH_SLASHES_AS_UNDERSCORES>.json" and the
# same prefix with a ".status" suffix. The body file contains the
# raw bytes to return; the status file contains a single integer
# HTTP status. Every request is recorded into
# "$FIXTURES_DIR/requests.log" (one line per request: METHOD PATH).
# DELETE calls additionally go into "$FIXTURES_DIR/delete_calls.log"
# (just the path), since DELETE responses are usually empty and we
# still want to assert the right hash was passed.
#
# Why not python -m http.server
# -----------------------------
# http.server cannot serve method-routed fixtures; every path
# returns the directory listing or 404. The python loop below is
# ~50 lines and gives us per-path body + status control with no
# third-party dependencies.
#
# Why bash on the outside
# -----------------------
# The test starts the mock as a background process and needs a
# portable way to: print the chosen port to stdout, redirect logs
# to a file, and be killed cleanly on teardown. Bash does that with
# no extra setup. The actual HTTP loop is in python because that's
# the most reliable way to get a ThreadingHTTPServer.

set -euo pipefail

PORT="${MOCK_PORT:-${1:-18765}}"
FIXTURES_DIR="${MOCK_FIXTURES_DIR:-/tmp/openrouter-mock-$PORT}"
REQUESTS_LOG="$FIXTURES_DIR/requests.log"
DELETE_LOG="$FIXTURES_DIR/delete_calls.log"

mkdir -p "$FIXTURES_DIR"
: > "$REQUESTS_LOG"
: > "$DELETE_LOG"

# Refuse to start if the port is already in use. The tests pick a
# unique port per setup() so this should not fire in practice; the
# guard is here so we don't silently double-bind.
if (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
	echo "mock-openrouter: port $PORT is already in use" >&2
	exit 1
fi

# Print the port first so the parent test can capture it even if
# the python server fails to bind.
echo "$PORT"

exec python3 - "$PORT" "$FIXTURES_DIR" "$REQUESTS_LOG" "$DELETE_LOG" <<'PY'
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
fixtures = sys.argv[2]
requests_log = sys.argv[3]
delete_log = sys.argv[4]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # silence default stderr access log
        pass

    def _handle(self, method):
        path = self.path
        with open(requests_log, "a") as f:
            f.write(f"{method} {path}\n")
        if method == "DELETE":
            with open(delete_log, "a") as f:
                f.write(f"{path}\n")
            body = b'{"data":null}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        norm = path.replace("/", "_")
        body_path = os.path.join(fixtures, f"{method}_{norm}.json")
        status_path = os.path.join(fixtures, f"{method}_{norm}.status")
        status = 200
        body = b"{}"
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

    def do_DELETE(self):
        self._handle("DELETE")


httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
httpd.serve_forever()
PY
