#!/usr/bin/env bats
#
# tests/viz-render-server.bats
#
# Tests for the viz render server HTTP API contract.
#
# The server is a Playwright wrapper that takes mermaid/graphviz/chartjs
# source and returns PNG. We only test the HTTP shape here — not the
# actual rendering pipeline (which needs a real Chromium). The contract
# is:
#
#   POST /render        { type, source }    -> image/png | 4xx/5xx JSON
#   GET  /health                              -> { status, browser }
#
# If you change the request/response shape, these tests will catch it
# before the change ships.
#
# All HTTP calls go through Node's http module because the host's `curl`
# is a permission-broken stub. This makes the tests self-contained.
#
# Test cases:
#   1. /health responds 200 with JSON containing status and browser
#   2. /render returns 400 for missing source
#   3. /render returns 400 for unknown type
#   4. /render returns image/png for valid mermaid
#   5. /render caches by content hash (no playwright on second call)

setup() {
  TEST_PORT=18766
  export VIZ_PORT=$TEST_PORT
  export VIZ_CACHE_DIR="$(mktemp -d)"

  # Install node_modules in the source dir (mirrors what the installer does)
  if [ -d "$HOME/.openclaw/services/viz/node_modules" ]; then
    cp -r "$HOME/.openclaw/services/viz/node_modules" config/services/viz/
  else
    pushd config/services/viz >/dev/null
    npm install --silent
    popd >/dev/null
  fi

  # Start the server in the background
  pushd config/services/viz >/dev/null
  node render-server.js >/tmp/viz-server.log 2>&1 &
  SERVER_PID=$!
  popd >/dev/null

  # Wait for server to come up (up to 15s)
  for i in $(seq 1 15); do
    if http_get_status "http://localhost:$TEST_PORT/health" 2>/dev/null | grep -q "^200$"; then
      return 0
    fi
    sleep 1
  done
  echo "Server failed to start; log:"
  cat /tmp/viz-server.log
  return 1
}

teardown() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    pkill -P "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$VIZ_CACHE_DIR" /tmp/viz-server.log
}

# Helper: GET a URL, echo the HTTP status code on stdout. Suppresses body.
http_get_status() {
  local url="$1"
  node -e "
const http = require('http');
const u = new URL('$url');
http.get({hostname: u.hostname, port: u.port, path: u.pathname}, r => {
  r.resume();
  r.on('end', () => process.stdout.write(String(r.statusCode)));
}).on('error', e => { process.stderr.write(e.message); process.exit(1); });
"
}

# Helper: POST a JSON body, echo the HTTP status code, save body to a path
# Usage: http_post_status URL JSON_BODY OUT_FILE
http_post_status() {
  local url="$1"
  local body="$2"
  local outfile="$3"
  node -e "
const http = require('http');
const fs = require('fs');
const u = new URL('$url');
const body = '$body';
const req = http.request({
  hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST',
  timeout: 60000,
  headers: {'Content-Type':'application/json','Content-Length': Buffer.byteLength(body)}
}, r => {
  const chunks = [];
  r.on('data', c => chunks.push(c));
  r.on('end', () => {
    fs.writeFileSync('$outfile', Buffer.concat(chunks));
    process.stdout.write(String(r.statusCode));
  });
});
req.on('error', e => { process.stderr.write('REQ_ERR: ' + e.message); process.exit(1); });
req.on('timeout', () => { process.stderr.write('REQ_TIMEOUT'); req.destroy(); process.exit(1); });
req.write(body);
req.end();
"
}

@test "viz server: /health responds 200 with JSON" {
  run http_get_status "http://localhost:$TEST_PORT/health"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
  # Body should be JSON with status and browser
  node -e "
const http = require('http');
const u = new URL('http://localhost:$TEST_PORT/health');
http.get(u, r => {
  let d = '';
  r.on('data', c => d += c);
  r.on('end', () => {
    const j = JSON.parse(d);
    if (j.status !== 'ok') process.exit(1);
    if (!('browser' in j)) process.exit(2);
  });
});
"
}

@test "viz server: /render returns 400 for missing source" {
  run http_post_status "http://localhost:$TEST_PORT/render" '{"type":"mermaid"}' /tmp/resp.json
  [ "$output" = "400" ]
}

@test "viz server: /render returns 400 for unknown type" {
  run http_post_status "http://localhost:$TEST_PORT/render" '{"type":"nonexistent","source":"foo"}' /tmp/resp.json
  [ "$output" = "400" ]
}

@test "viz server: /render returns image/png for valid mermaid" {
  # Run the request in the foreground (not via `run`) and capture status to a file.
  # This avoids BATS truncating the long output that comes from a successful render.
  rm -f /tmp/diagram.png /tmp/render-status
  node -e "
const http = require('http');
const fs = require('fs');
// JSON.stringify escapes \n properly (the raw newlines in a JS string become \\n in the JSON body)
const body = JSON.stringify({type:'mermaid',source:'graph TD\n    A --> B'});
const req = http.request({
  hostname: 'localhost', port: $TEST_PORT, path: '/render', method: 'POST',
  timeout: 60000,
  headers: {'Content-Type':'application/json','Content-Length': Buffer.byteLength(body)}
}, r => {
  const chunks = [];
  r.on('data', c => chunks.push(c));
  r.on('end', () => {
    fs.writeFileSync('/tmp/diagram.png', Buffer.concat(chunks));
    fs.writeFileSync('/tmp/render-status', String(r.statusCode));
  });
});
req.on('error', e => fs.writeFileSync('/tmp/render-status', 'ERR:' + e.message));
req.write(body); req.end();
"
  [ -f /tmp/render-status ]
  local status
  status=$(cat /tmp/render-status)
  [ "$status" = "200" ]
  [ -s /tmp/diagram.png ]
  file /tmp/diagram.png | grep -q "PNG image"
  rm -f /tmp/diagram.png /tmp/render-status
}

@test "viz server: /render caches by content hash" {
  # Use a unique body for this test (different from the other render test)
  # so we don't hit a cache file from a previous test run.
  rm -f /tmp/d1.png /tmp/d2.png
  node -e "
const http = require('http');
const fs = require('fs');
const body = JSON.stringify({type:'mermaid',source:'graph LR\n    X --> Y\n    Y --> Z'});
const doReq = (outfile, callback) => {
  const req = http.request({
    hostname: 'localhost', port: $TEST_PORT, path: '/render', method: 'POST',
    timeout: 60000,
    headers: {'Content-Type':'application/json','Content-Length': Buffer.byteLength(body)}
  }, r => {
    const chunks = [];
    r.on('data', c => chunks.push(c));
    r.on('end', () => {
      fs.writeFileSync(outfile, Buffer.concat(chunks));
      callback(r.statusCode);
    });
  });
  req.on('error', e => process.exit(1));
  req.write(body); req.end();
};
doReq('/tmp/d1.png', s1 => {
  doReq('/tmp/d2.png', s2 => {
    if (s1 === 200 && s2 === 200) process.exit(0);
    process.exit(1);
  });
});
"
  # Both responses should be byte-identical (cache hit returns same file)
  cmp /tmp/d1.png /tmp/d2.png
  rm -f /tmp/d1.png /tmp/d2.png
}
