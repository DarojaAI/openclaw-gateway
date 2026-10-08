import os
import sys
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# CodeQL py/path-injection hardening: every path passed to open()/exists()
# is built from this helper's own directory (__file__) plus a real filename
# returned by os.listdir(); no request data ever flows into a path sink.
# Fixture names derived from the HTTP request path (basename, validated
# against a whitelist regex) are used only as comparison keys against the
# directory listing.

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
        with open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "requests.log"), "a") as f:
            f.write(f"{method} {raw_path}\n")
        if method == "DELETE":
            with open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "delete_calls.log"), "a") as f:
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
        # CodeQL py/path-injection: no open()/exists() path is ever built
        # from request data. The request-derived expected name is used
        # only as a comparison key against entries from os.listdir();
        # every open() receives a real filename from disk (listdir), so
        # no tainted value reaches a path sink.
        match = f"{method}_{norm}"
        status = 200
        body = b"{}"
        for response in os.listdir(os.path.join(os.path.dirname(os.path.realpath(__file__)), "fixtures")):
            base, ext = os.path.splitext(response)
            if base != match:
                continue
            if ext == ".status":
                with open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "fixtures", response)) as f:
                    status = int(f.read().strip() or 200)
            elif ext == ".json":
                with open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "fixtures", response), "rb") as f:
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
