import os
import sys
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# CodeQL py/path-injection hardening: all file-access paths are module-level
# constants derived from this helper's own directory, not from argv, so no
# untrusted values reach an open() sink ( no taint flow.  Fixture lookup
# names come fromtheHTTP request path and are reduced to their basename, then
# validated against a whitelist regex before any path is built..
_HERE = os.path.dirname(os.path.realpath(__file__))
FIXTURES_DIR = os.path.join(_HERE, "fixtures")
REQUESTS_LOG = os.path.join(_HERE, "requests.log")
DELETE_LOG = os.path.join(_HERE, "delete_calls.log")

port = int(sys.argv[1])
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
        with open(REQUESTS_LOG, "a") as f:
            f.write(f"{method} {raw_path}\n")
        if method == "DELETE":
            with open(DELETE_LOG, "a") as f:
                f.write(f"{raw_path}\n")
            body = b'{"data":null}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        norm = req_name.replace("/", "_")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", norm):
            self.send_error(404)
            return
        fixtures_root = os.path.realpath(FIXTURES_DIR)
        body_path = os.path.realpath(os.path.join(FIXTURES_DIR, f"{method}_{norm}.json"))
        status_path = os.path.realpath(os.path.join(FIXTURES_DIR, f"{method}_{norm}.status"))
        if os.path.commonpath([fixtures_root, body_path]) != fixtures_root:
            self.send_error(404)
            return
        if os.path.commonpath([fixtures_root, status_path]) != fixtures_root:
            self.send_error(404)
            return
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
