#!/usr/bin/env python3
"""diagnose-gateway-start-failure — evidence collector for gateway start failures.

Born from issue #165: the openclaw binary swallows bootstrap exceptions
("The CLI command failed." with no diagnostic), so during a systemd crash
loop the operator flies blind. This collector runs the read-only surfaces
that DO reveal the cause — `openclaw doctor --lint` (binary diagnostics),
the gateway unit journal, state-dir sidecar state, and disk headroom — and
prints a structured report with a verdict for the known failure classes.

Read-only by design (boundary lane C1/C4 — see linux-desktop-seed
docs/contracts/SQLITE-STATE-BOUNDARY.md). Never writes, never repairs:
repair decisions belong to openclaw (doctor --fix) or the documented
restore protocol.

Exit codes: 0 report collected (check the VERDICT line); 1 collector could
not run at all.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
JOURNAL_UNIT = "openclaw-gateway.service"
STATE_DIR = HOME / ".openclaw" / "state"
CORRUPTION_MARKERS = ("malformed", "database disk image is corrupted", "SQLITE_CORRUPT")
UNIT = "openclaw-gateway.service"


def run(cmd: list[str], timeout: int = 30) -> tuple[int, str]:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, f"[collector: {cmd[0]} failed: {exc}]"


def section(title: str, body: str) -> str:
    return f"### {title}\n{body.strip() or '(no output)'}\n"


def main() -> int:
    parts: list[str] = []

    rc, lint = run(["openclaw", "doctor", "--lint"], timeout=110)
    parts.append(section("doctor --lint", lint))
    corruption = any(marker in lint for marker in CORRUPTION_MARKERS)

    rc_j, journal = run(
        ["journalctl", "--user", "-u", UNIT, "-n", "60", "--no-pager", "-o", "cat"],
        timeout=30,
    )
    parts.append(section("gateway journal (last 60 lines)", journal if rc_j == 0 else journal))

    sidecars = sorted(
        str(p) for p in STATE_DIR.glob("openclaw.sqlite-*")
        if p.name.endswith(("-wal", "-shm"))
    ) if STATE_DIR.is_dir() else []
    live = run(["systemctl", "--user", "is-active", "--quiet", UNIT])[0] == 0
    sidecar_verdict = ""
    if sidecars and not live:
        sidecar_verdict = (
            "UNCLEAN-CLOSE SIGNATURE: sidecars present while the gateway is "
            "stopped — SQLite deletes them on last clean close (2026-10-19 "
            "corruption precondition)"
        )
    parts.append(section(
        "state sidecars",
        "\n".join(sidecars) if sidecars else "none present"
        + (f"\nVERDICT-ADVISORY: {sidecar_verdict}" if sidecar_verdict else "")
        + f"\ngateway unit: {'active' if live else 'stopped'}",
    ))

    rc_df, df = run(["df", "-h", "/"])
    parts.append(section("disk headroom", df))

    print("# gateway start-failure diagnostics")
    print("\n".join(parts))

    if corruption:
        print(
            "VERDICT: corruption signature in doctor --lint output — per the\n"
            "documented refusal path: PRESERVE the database and its WAL, then\n"
            "restore a verified backup (SQLITE-STATE-BOUNDARY.md C2/C4).\n"
            "Do not delete, do not restart-and-hope, do not hand-REINDEX."
        )
    elif sidecar_verdict:
        print(f"VERDICT: {sidecar_verdict}.")
    disk_pct = [int(m) for m in re.findall(r"(\d{1,3})%\s+/", df)]
    if "No space left on device" in df or any(pct >= 90 for pct in disk_pct):
        print("VERDICT: disk-pressure signature — free space before any retry.")
    else:
        print("VERDICT: no known failure signature — see the raw sections above.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
