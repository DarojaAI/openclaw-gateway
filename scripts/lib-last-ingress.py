#!/usr/bin/env python3
# scripts/lib-last-ingress.py
#
# Helper for lane-health-probe.sh and post-deploy-verify-lane-health.sh.
# Reads gateway log lines on stdin and reports the age of the most recent
# successful Discord receive/drain event.
#
# Why this exists:
# Issue #135: /healthz returned 200 for 2h+ while the Discord ingress was
# dead (the gateway process was up and answering health checks, but had
# silently stopped draining incoming Discord messages). A lane-existence
# / process-up check cannot see this; only the *freshness* of incoming
# Discord traffic can.
#
# A receive event is any log line matching INGRESS_FRESHNESS_MARKER (a
# regex, defaulted below). The marker is deliberately configurable via env
# because the exact wording of the upstream openclaw runtime's receive line
# varies by version — operators pin it to their gateway's actual log line via
# INGRESS_FRESHNESS_MARKER when the default does not match.
#
# Timestamps are parsed from the syslog prefix the gateway journal and the
# rotating-file fallback both use: "Jun 28 18:48:41 host openclaw[...]: ...".
#
# Args (env vars):
#   INGRESS_FRESHNESS_MARKER  regex matched against the whole line to decide
#                             whether a line is a Discord receive/drain event
#                             (default: see DEFAULT_MARKER)
#
# Output (one JSON object on stdout):
#   {"found": true|false, "markerCount": n, "lastReceive": "…Z",
#    "ageSeconds": n}   — lastReceive/ageSeconds present only when found.
#
# Exit codes:
#   0 = parsed (even if no receive found — callers decide the verdict)

import datetime as dt
import json
import os
import re
import sys

# Default marker: a Discord-flavoured intake line. Broad on purpose — we
# prefer a false "found" over a false "stale" given Issue #135 costs 2h of
# silent downtime. Match the whole line case-insensitively, requiring a
# Discord-ish token and an intake verb nearby.
DEFAULT_MARKER = (
    r"(?i)discord.{0,120}"
    r"(receiv|incom|message|event|drain|ingest|handl|deliver)"
)


def _clamp_year(parsed: dt.datetime, now: dt.datetime) -> dt.datetime:
    # Syslog has no year; assume the current year, but rewind one year if
    # that lands in the future (e.g. a "Dec 31" line seen on Jan 1).
    parsed = parsed.replace(year=now.year)
    if parsed > now + dt.timedelta(days=1):
        parsed = parsed.replace(year=now.year - 1)
    return parsed


def main() -> int:
    marker_src = os.environ.get("INGRESS_FRESHNESS_MARKER", "")
    pat = re.compile(marker_src if marker_src else DEFAULT_MARKER)

    now = dt.datetime.utcnow()
    newest = None
    count = 0
    for line in sys.stdin:
        if not pat.search(line):
            continue
        # Syslog prefix "Jun 28 18:48:41" == first 15 chars.
        try:
            parsed = dt.datetime.strptime(line[:15], "%b %d %H:%M:%S")
        except ValueError:
            continue
        parsed = _clamp_year(parsed, now)
        if newest is None or parsed > newest:
            newest = parsed
        count += 1

    out = {"found": newest is not None, "markerCount": count}
    if newest is not None:
        out["lastReceive"] = newest.strftime("%Y-%m-%dT%H:%M:%SZ")
        out["ageSeconds"] = max(0, int((now - newest).total_seconds()))
    print(json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())