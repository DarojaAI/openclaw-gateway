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
        # Strip the query string for fixture routing — the provisioner
        # now paginates with ``?limit=100&offset=N`` and a future caller
        # might add other filters. Fixtures are keyed on METHOD+PATH,
        # not on query params; otherwise each paginated call would need
        # its own fixture file and a single canonical mock couldn't
        # serve a multi-page sequence with one body. If a future test
        # needs to assert on query params, the requests.log records the
        # raw path (with query string) for that purpose.
        from urllib.parse import urlsplit
        raw_path = self.path
        path = urlsplit(raw_path).path
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
