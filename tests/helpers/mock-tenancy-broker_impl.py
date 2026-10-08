import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
# NOTE: paths below derive from argv supplied by the test harness
# (localhost-only mock servers started by bats). The lgtm
# suppressions mark this as reviewed: not a security boundary.


port = int(sys.argv[1])
fixtures = sys.argv[2]
requests_log = sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # silence default stderr access log
        pass

    def _handle(self, method):
        from urllib.parse import urlsplit
        path = urlsplit(self.path).path
        with open(requests_log, "a") as f:  # lgtm[py/path-injection] test-harness argv, not a boundary
            f.write(f"{method} {self.path}\n")
        norm = path.replace("/", "_")
        body_path = os.path.join(fixtures, f"{method}_{norm}.json")
        status_path = os.path.join(fixtures, f"{method}_{norm}.status")
        status = 200
        body = b'{"triple": null, "valid": false, "exp": null}'
        if os.path.exists(status_path):
            with open(status_path) as f:  # lgtm[py/path-injection] test-harness argv, not a boundary
                status = int(f.read().strip() or 200)
        if os.path.exists(body_path):
            with open(body_path, "rb") as f:  # lgtm[py/path-injection] test-harness argv, not a boundary
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
