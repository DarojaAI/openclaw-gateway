#!/usr/bin/env python3
"""
Lifecycle endpoint for the daroja-intelligence-console.

Serves /healthz and /lifecycle over HTTP. The /lifecycle response matches
the console's LifecycleReport shape: {sessions, crons, lessons, captured_at}.

Sessions are read from OpenClaw trajectory files
(~/.openclaw/agents/*/sessions/*.trajectory.jsonl) using the same pattern
as cost-monitor.py. Crons and lessons are not yet available from this repo
and return empty arrays.

Usage:
    python3 scripts/lifecycle.py [--port 8099] [--host 127.0.0.1]

Refs: DarojaAI/openclaw-gateway#108
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Data source paths (honors env vars for test isolation)
# ---------------------------------------------------------------------------

AGENTS_ROOT = Path(
    os.environ.get("OPENCLAW_AGENTS_ROOT") or Path.home() / ".openclaw" / "agents"
)

LOCKFILE_PATH = Path(
    os.environ.get("OPENCLAW_LOCKFILE")
    or Path(__file__).resolve().parent.parent / "config" / "agents.lock.toml"
)

# ---------------------------------------------------------------------------
# Session collector — reads trajectory files
# ---------------------------------------------------------------------------

def collect_sessions(agents_root: Path | None = None) -> list[dict[str, Any]]:
    """Summarise sessions from trajectory files.

    Returns a list of session summaries, one per trajectory file, sorted
    by most-recent-event first. Each summary contains:
      - agent_id: the agent that owns the session
      - session_file: basename of the trajectory file
      - last_event_at: ISO timestamp of the most recent event
      - event_count: total events in the file
      - models_used: deduplicated list of model IDs seen
    """
    root = agents_root or AGENTS_ROOT
    if not root.is_dir():
        return []

    sessions: list[dict[str, Any]] = []
    for traj in sorted(root.glob("*/sessions/*.trajectory.jsonl")):
        agent_id = traj.parent.parent.name  # agents/<id>/sessions/<file>
        event_count = 0
        last_ts = ""
        models: set[str] = set()
        try:
            with traj.open("r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    event_count += 1
                    ts = event.get("ts", "")
                    if ts > last_ts:
                        last_ts = ts
                    mid = event.get("modelId")
                    if mid:
                        models.add(mid)
        except OSError:
            continue
        sessions.append({
            "agent_id": agent_id,
            "session_file": traj.name,
            "last_event_at": last_ts or None,
            "event_count": event_count,
            "models_used": sorted(models),
        })

    # Most recent first
    sessions.sort(key=lambda s: s.get("last_event_at") or "", reverse=True)
    return sessions


# ---------------------------------------------------------------------------
# Cron collector — stub (no data source in this repo yet)
# ---------------------------------------------------------------------------

def collect_crons() -> list[dict[str, Any]]:
    """Return cron summaries. Currently a stub — cron config lives in
    the OpenClaw gateway runtime, not in this config repo."""
    return []


# ---------------------------------------------------------------------------
# Lesson collector — stub (no data source in this repo yet)
# ---------------------------------------------------------------------------

def collect_lessons() -> list[dict[str, Any]]:
    """Return lesson summaries. Currently a stub — lesson data is not yet
    tracked in this repo."""
    return []


# ---------------------------------------------------------------------------
# Lifecycle report
# ---------------------------------------------------------------------------

def build_lifecycle_report() -> dict[str, Any]:
    """Build the full lifecycle report matching the console's shape."""
    return {
        "sessions": collect_sessions(),
        "crons": collect_crons(),
        "lessons": collect_lessons(),
        "captured_at": datetime.now(timezone.utc).isoformat(),
    }


# ---------------------------------------------------------------------------
# HTTP server (stdlib only)
# ---------------------------------------------------------------------------

class LifecycleHandler(BaseHTTPRequestHandler):
    """Handle /healthz and /lifecycle GET requests."""

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._json_response(200, {"status": "ok"})
        elif self.path == "/lifecycle":
            report = build_lifecycle_report()
            self._json_response(200, report)
        else:
            self._json_response(404, {"error": "not found"})

    def _json_response(self, code: int, body: dict[str, Any]) -> None:
        payload = json.dumps(body, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args: Any) -> None:
        # Quiet default; override to stderr for visibility
        sys.stderr.write(f"[lifecycle] {fmt % args}\n")


def serve(host: str = "127.0.0.1", port: int = 8099) -> None:
    """Start the lifecycle HTTP server."""
    server = HTTPServer((host, port), LifecycleHandler)
    print(f"Lifecycle endpoint listening on http://{host}:{port}")
    print(f"  GET /healthz   — health check")
    print(f"  GET /lifecycle — lifecycle report")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Lifecycle endpoint for daroja-intelligence-console"
    )
    parser.add_argument("--port", type=int, default=8099, help="Port to listen on")
    parser.add_argument(
        "--host", default="127.0.0.1", help="Host to bind to"
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Print lifecycle report to stdout and exit (no server)",
    )
    args = parser.parse_args()

    if args.once:
        report = build_lifecycle_report()
        print(json.dumps(report, indent=2))
        return 0

    serve(host=args.host, port=args.port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
