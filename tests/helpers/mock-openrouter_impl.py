import os
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
# Security hardening for CodeQL py/path-injection: even though this mock is
# localhost-only test infrastructure, cheap guards keep untrusted input out
# of the file-access paths.  Both kinds of file path are constrained:
#   argv-supplied paths (the fixtures dir and both request logs) must resolve
#   inside this helper's own directory orthe system-wide temp dir; anything else
#   aborts startup.  Fixture lookup names derived fromtheHTTP request path are
#   reduced to their basename, so request paths cannot alias arbitrary files.. No
#   absolute or parent segments can drive the fixture lookup..

_here = os.path.realpath(__file__)
_HERE = os.path.dirname(_here)
_tmp_dir = tempfile.gettempdir()
_TMP_ROOT = os.path.realpath(_tmp_dir)
_ALLOWED_ROOTS = (_HERE, _TMP_ROOT)


def _safe_argv_path(name, value):
    real = os.path.realpath(value)
    ok = False
    for root in _ALLOWED_ROOTS:

        if real == root:
            ok = True
        if real.startswith(root + os.sep):
            ok = True
    if not ok:
        raise SystemExit(f"mock-openrouter: refusing {name} outside allowed roots: {value}")
    return real


port = int(sys.argv[1])
fixtures = _safe_argv_path("fixtures dir", sys.argv[2])
requests_log = _safe_argv_path("requests log", sys.argv[3])
delete_log = _safe_argv_path("delete log", sys.argv[4])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # silence default stderr access log
        pass

    def _handle(self, method):
        # Strip the query string for fixture routing — the provisioner
        # now paginates with ``?limit=100&offset=N`` and a future caller
        # might add other filters. Fixture names use the basename of the PATH, keyed on METHOD,
        # not on query params; otherwise each paginated call would need
        # its own fixture file and a single canonical mock couldn't
        # serve a multi-page sequence with one body. If a future test
        # needs to assert on query params, the requests.log records the
        # raw path (with query string) for that purpose.
        from urllib.parse import urlsplit
        raw_path = self.path
        parsed = urlsplit(raw_path)
        req_name = os.path.basename(parsed.path)
        req_name = req_name.strip("/")
        if not req_name:
            req_name = "index"
        with open(requests_log, "a") as f:
            f.write(f"{method} {raw_path}\n")
        if method == "DELETE":
            with open(delete_log, "a") as f:
                f.write(f"{raw_path}\n")
            body = b'{"data":null}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        norm = req_name.replace("/", "_")
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
