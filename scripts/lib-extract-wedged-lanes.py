#!/usr/bin/env python3
# scripts/lib-extract-wedged-lanes.py
#
# Helper for lane-health-probe.sh and post-deploy-verify-lane-health.sh.
# Reads gateway log lines on stdin, prints one JSON object per wedged
# lane on stdout.
#
# Wedged = a `long-running session` event matching:
#   - classification=long_running
#   - recovery=none OR recovery=manual
#   - any activeWorkKind (model_call, tool_call, ...)
#
# Callers decide what to do with the output (kill, alert, gate fail).
#
# Args (env vars):
#   WEDGED_MIN_AGE_SECONDS   only emit entries with age >= this (default: 0)
#
# Output schema (one JSON object per line):
#   {"sessionKey": "...", "ageSeconds": 275, "queueDepth": 3,
#    "activeWorkKind": "...", "lastProgress": "...", "lastProgressAge": 5,
#    "recovery": "none"}

import json
import os
import re
import sys

MIN_AGE = int(os.environ.get("WEDGED_MIN_AGE_SECONDS", "0"))

PAT = re.compile(
    r"long-running session:"
    r"\s*sessionId=(?P<sessionId>\S+)\s+"
    r"sessionKey=(?P<sessionKey>\S+)\s+"
    r"state=\S+\s+age=(?P<age>\d+)s\s+"
    r"queueDepth=(?P<queueDepth>\d+)"
    r"(?:\s+reason=\S+)?"
    r"\s+classification=long_running\s+"
    r"activeWorkKind=(?P<activeWorkKind>\S+)\s+"
    r"lastProgress=(?P<lastProgress>\S+)\s+"
    r"lastProgressAge=(?P<lastProgressAge>\d+)s"
    r"(?:\s+activeTool=\S+(?:\s+activeToolCallId=\S+)?(?:\s+activeToolAge=\d+s)?)?"
    r"\s+recovery=(?P<recovery>\S+)"
)


def main() -> int:
    for line in sys.stdin:
        m = PAT.search(line)
        if not m:
            continue
        d = m.groupdict()
        age = int(d["age"])
        if age < MIN_AGE:
            continue
        d["ageSeconds"] = age
        d["queueDepth"] = int(d["queueDepth"])
        d["lastProgressAge"] = int(d["lastProgressAge"])
        # Drop sessionId; it's not used by the probe or verifier.
        d.pop("sessionId", None)
        print(json.dumps(d, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
