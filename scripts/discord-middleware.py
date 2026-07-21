#!/usr/bin/env python3
"""
Discord message middleware for bridge syntax + capabilities (RFC #31).

Processes a Discord message through the full routing pipeline:

  1. Bridge syntax detection  (@A ask @B → source + target)
  2. @handle / @capability routing
  3. Quarantine check
  4. Canary routing
  5. Channel pinning
  6. Audit logging

Usage:
    echo '{"content":"@darojaai hello","channel_id":"123","author_id":"456"}' \\
        | python3 scripts/discord-middleware.py

    python3 scripts/discord-middleware.py --message '{"content":"hello"}'

    python3 scripts/discord-middleware.py --enforce --message '{"content":"@bad-agent hi"}'

Modes:
    --dry-run   (default) — log violations but always exit 0
    --enforce             — block on quarantine or channel-pinning violations (exit 1)

Exit codes:
    0 — dry-run pass-through (always, even on violations)
    1 — enforce mode: message blocked (quarantine or channel-pinning)

Refs:
    DarojaAI/openclaw-gateway#69
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Import only modules whose filenames don't contain hyphens.
# Hyphenated scripts (bridge-syntax.py, route-by-handle.py,
# capability-dispatch.py) are called as subprocesses.
# ---------------------------------------------------------------------------

from _agents_lock import load_agents_lock
from quarantine import is_quarantined, get_quarantine_info

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPTS_DIR = Path(__file__).resolve().parent
PIPELINE_VERSION = "1"

# Regex to detect bridge syntax: @A ask @B <question>
BRIDGE_RE = re.compile(
    r'^@([A-Za-z0-9_-]+)\s+ask\s+@([A-Za-z0-9_-]+)\s+(.+)$'
)

HANDLE_RE = re.compile(r'@([A-Za-z0-9_-]+)')


# ---------------------------------------------------------------------------
# Subprocess helpers — call the hyphenated scripts
# ---------------------------------------------------------------------------


def _run_bridge_syntax(
    content: str, lockfile: Path
) -> dict[str, Any] | None:
    """Call bridge-syntax.py and return parsed JSON, or None on failure."""
    try:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPTS_DIR / "bridge-syntax.py"),
                content,
                str(lockfile),
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        # Best-effort helper: subprocess/parse failures are treated as no route.
        return None
    return None


def _run_route_by_handle(
    handle: str, lockfile: Path
) -> dict[str, Any] | None:
    """Call route-by-handle.py (no --channel, no quarantine check
    interference) and return parsed JSON, or None on failure."""
    try:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPTS_DIR / "route-by-handle.py"),
                "--lockfile", str(lockfile),
                "--handle", handle,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        # Treat subprocess/parse failures as "no route" to preserve middleware pass-through behavior.
        return None
    return None


def _run_capability_dispatch(
    content: str, lockfile: Path, dry_run: bool = True
) -> dict[str, Any] | None:
    """Call capability-dispatch.py and return parsed JSON, or None."""
    cmd = [
        sys.executable,
        str(SCRIPTS_DIR / "capability-dispatch.py"),
        "--lockfile", str(lockfile),
        "--message", content,
    ]
    if dry_run:
        cmd.append("--dry-run")
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            raw = json.loads(result.stdout)
            # Unwrap dry_run wrapper if present
            return raw.get("would_route_to", raw)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        pass
    return None


def _run_canary_routing(
    handle: str, lockfile: Path
) -> dict[str, Any] | None:
    """Call canary_routing.py and return parsed JSON, or None."""
    try:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPTS_DIR / "canary_routing.py"),
                "--lockfile", str(lockfile),
                "--handle", handle,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        pass
    return None


# ---------------------------------------------------------------------------
# Core pipeline
# ---------------------------------------------------------------------------


def run_pipeline(
    message: dict[str, Any],
    lockfile_path: Path,
    *,
    channel_id: str | None = None,
    override_handle: str | None = None,
) -> dict[str, Any]:
    """Run the full routing pipeline and return a decision dict."""
    content: str = message.get("content", "")
    msg_channel: str = message.get("channel_id", "")
    effective_channel = channel_id or msg_channel or ""

    decision: dict[str, Any] = {
        "pipeline_version": PIPELINE_VERSION,
        "message": message,
        "dry_run": True,
        "blocked": False,
        "blocked_reason": None,
        "steps": [],
        "routing": None,
        "violations": [],
    }

    # Load registry once (used by all branches)
    registry = load_agents_lock(lockfile_path)
    if not registry:
        decision["steps"].append("registry_empty")
        return decision

    agents = registry.get("agents", {})

    # --- Step 1: Bridge syntax detection ---
    m = BRIDGE_RE.match(content.strip())
    if m:
        decision["steps"].append("bridge_syntax")
        source_handle = f"@{m.group(1)}"
        target_handle = f"@{m.group(2)}"
        question = m.group(3).strip()
        source_slug = m.group(1)
        target_slug = m.group(2)

        # Find TOML slugs for quarantine checks (hyphen→underscore normalization)
        source_toml_slug = source_slug
        target_toml_slug = target_slug
        for slug, agent in agents.items():
            if agent.get("handle", "") == source_handle:
                source_toml_slug = slug
            if agent.get("handle", "") == target_handle:
                target_toml_slug = slug

        # Quarantine: check source
        if is_quarantined(source_toml_slug, lockfile_path):
            decision["steps"].append("quarantine_source")
            info = get_quarantine_info(source_toml_slug, lockfile_path)
            reason = (info or {}).get("reason", "unknown")
            decision["blocked"] = True
            decision["blocked_reason"] = (
                f"source agent {source_handle} is quarantined: {reason}"
            )
            decision["violations"].append(decision["blocked_reason"])
            return decision

        # Quarantine: check target
        if is_quarantined(target_toml_slug, lockfile_path):
            decision["steps"].append("quarantine_target")
            info = get_quarantine_info(target_toml_slug, lockfile_path)
            reason = (info or {}).get("reason", "unknown")
            decision["blocked"] = True
            decision["blocked_reason"] = (
                f"target agent {target_handle} is quarantined: {reason}"
            )
            decision["violations"].append(decision["blocked_reason"])
            return decision

        # Routing: try bridge-syntax.py first, fall back to registry lookup
        decision["steps"].append("routing")
        bs_result = _run_bridge_syntax(content, lockfile_path)
        if bs_result is not None:
            decision["routing"] = {
                "source_agent": bs_result.get("source_agent", {}),
                "target_agent": bs_result.get("target_agent", {}),
                "question": bs_result.get("question", question),
            }
        else:
            # Build from registry
            src_info = None
            tgt_info = None
            for slug, agent in agents.items():
                if agent.get("handle", "") == source_handle:
                    src_info = {"handle": source_handle, "slug": slug, "repo": agent.get("repo", "")}
                if agent.get("handle", "") == target_handle:
                    tgt_info = {"handle": target_handle, "slug": slug, "repo": agent.get("repo", "")}
            if src_info is None:
                decision["violations"].append(f"unknown source agent {source_handle}")
                return decision
            if tgt_info is None:
                decision["violations"].append(f"unknown target agent {target_handle}")
                return decision
            decision["routing"] = {"source_agent": src_info, "target_agent": tgt_info, "question": question}

        # Canary routing on target
        decision["steps"].append("canary_routing")
        cr = _run_canary_routing(target_slug, lockfile_path)
        if cr is not None:
            decision["routing"]["canary"] = cr.get("canary", {})

        # Channel pinning on target
        if effective_channel:
            decision["steps"].append("channel_pinning")
            tgt_entry = agents.get(target_slug)
            if tgt_entry is not None:
                from channel_pinning import check_channel_pinning
                pinning = check_channel_pinning(tgt_entry, effective_channel)
                decision["routing"]["channel_pinning"] = {
                    "channel_id": pinning["channel_id"],
                    "allowed_channels": pinning["allowed_channels"],
                    "violation": pinning["violation"],
                    "dry_run": pinning["dry_run"],
                    "enforced": pinning["enforced"],
                }
                if pinning["violation"]:
                    decision["violations"].append(
                        f"channel {effective_channel} not in allowed_channels for {target_handle}"
                    )
                    if pinning["enforced"]:
                        decision["blocked"] = True
                        decision["blocked_reason"] = (
                            f"channel pinning violation for {target_handle} in channel {effective_channel}"
                        )

        decision["steps"].append("audit_log")
        return decision

    # --- Step 2: @handle / @capability routing ---
    decision["steps"].append("routing")

    # Determine lookup token
    lookup_token: str | None = None
    if override_handle:
        lookup_token = override_handle.lstrip("@")
    else:
        handles = HANDLE_RE.findall(content)
        if handles:
            lookup_token = handles[0]

    if lookup_token is None:
        decision["steps"].append("no_handles")
        return decision

    # Quarantine check BEFORE calling subprocess.
    # Normalize lookup_token to TOML slug: find the matching agent in the
    # registry to get the actual key (e.g. "test_agent" not "test-agent").
    quarantine_slug = None
    for slug, agent in agents.items():
        agent_handle = agent.get("handle", "")
        if agent_handle == f"@{lookup_token}":
            quarantine_slug = slug
            break
    if quarantine_slug is None and lookup_token in agents:
        quarantine_slug = lookup_token
    if quarantine_slug and is_quarantined(quarantine_slug, lockfile_path):
        decision["steps"].append("quarantine")
        info = get_quarantine_info(quarantine_slug, lockfile_path)
        reason = (info or {}).get("reason", "unknown")
        decision["blocked"] = True
        decision["blocked_reason"] = f"agent @{lookup_token} is quarantined: {reason}"
        decision["violations"].append(decision["blocked_reason"])
        return decision

    # Try route-by-handle
    handle_result = _run_route_by_handle(lookup_token, lockfile_path)

    resolved_agent: dict[str, Any] | None = None
    agent_slug = ""

    if handle_result is not None:
        decision["routing"] = handle_result
        agent_slug = handle_result.get("slug", "")
        resolved_agent = agents.get(agent_slug)
    else:
        # Try capability dispatch
        cap_result = _run_capability_dispatch(content, lockfile_path, dry_run=True)
        if cap_result is not None:
            decision["routing"] = cap_result
            agent_slug = cap_result.get("slug", "")
            resolved_agent = agents.get(agent_slug)
        else:
            decision["steps"].append("unknown_handle")
            decision["violations"].append(f"unknown handle or capability @{lookup_token}")
            return decision

    # Canary routing
    decision["steps"].append("canary_routing")
    if agent_slug:
        cr = _run_canary_routing(agent_slug, lockfile_path)
        if cr is not None:
            decision["routing"]["canary"] = cr.get("canary", {})

    # Channel pinning (middleware does this, not the subprocess)
    if effective_channel and resolved_agent is not None:
        decision["steps"].append("channel_pinning")
        from channel_pinning import check_channel_pinning
        pinning = check_channel_pinning(resolved_agent, effective_channel)
        decision["routing"]["channel_pinning"] = {
            "channel_id": pinning["channel_id"],
            "allowed_channels": pinning["allowed_channels"],
            "violation": pinning["violation"],
            "dry_run": pinning["dry_run"],
            "enforced": pinning["enforced"],
        }
        if pinning["violation"]:
            decision["violations"].append(
                f"channel {effective_channel} not in allowed_channels for @{agent_slug}"
            )
            if pinning["enforced"]:
                decision["blocked"] = True
                decision["blocked_reason"] = (
                    f"channel pinning violation for @{agent_slug} in channel {effective_channel}"
                )

    decision["steps"].append("audit_log")
    return decision


# ---------------------------------------------------------------------------
# Audit log helper
# ---------------------------------------------------------------------------


def _write_audit_from_decision(
    decision: dict[str, Any],
    message: dict[str, Any],
) -> None:
    """Write an audit log entry from the pipeline decision."""
    routing = decision["routing"]
    if routing is None:
        return

    sys.path.insert(0, str(SCRIPTS_DIR))
    from audit_log import write_audit_entry

    channel_id = message.get("channel_id", "")

    if "source_agent" in routing and "target_agent" in routing:
        write_audit_entry(
            from_agent=routing["source_agent"].get("slug", ""),
            to_agent=routing["target_agent"].get("slug", ""),
            from_handle=routing["source_agent"].get("handle", ""),
            to_agent_handle=routing["target_agent"].get("handle", ""),
            contract_version="v1",
            capability="bridge",
            channel_id=channel_id,
        )
        return

    handle = routing.get("handle", "")
    slug = routing.get("slug", "")
    capability = routing.get("match_type", "handle")
    write_audit_entry(
        from_agent=slug,
        to_agent=slug,
        from_handle=handle,
        to_agent_handle=handle,
        contract_version="v1",
        capability=capability,
        channel_id=channel_id,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(
        description="Discord message middleware for bridge syntax + capabilities (RFC #31)",
    )
    parser.add_argument("--message", default=None, help="JSON message payload (alternative to stdin)")
    parser.add_argument("--dry-run", action="store_true", default=False, help="Log violations but always exit 0 (default)")
    parser.add_argument("--enforce", action="store_true", default=False, help="Block on quarantine or channel-pinning violations (exit 1)")
    parser.add_argument("--channel", default=None, help="Override channel_id for channel pinning checks")
    parser.add_argument("--handle", default=None, help="Override: route to this specific @handle")
    parser.add_argument("--lockfile", default=None, help="Path to agents.lock.toml")
    parser.add_argument("--audit", action="store_true", default=False, help="Write audit log entries")
    parser.add_argument("--audit-log", default=None, help="Audit log file path")
    args = parser.parse_args()

    raw: str | None = args.message
    if raw is None:
        raw = sys.stdin.read().strip()
    if not raw:
        print("ERROR: no message provided", file=sys.stderr)
        return 1

    try:
        message: dict[str, Any] = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"ERROR: invalid JSON message: {exc}", file=sys.stderr)
        return 1

    if args.lockfile:
        lockfile_path = Path(args.lockfile)
    else:
        lockfile_path = SCRIPTS_DIR.parent / "config" / "agents.lock.toml"

    if args.audit_log:
        os.environ["OPENCLAW_AUDIT_LOG"] = args.audit_log

    decision = run_pipeline(
        message,
        lockfile_path,
        channel_id=args.channel,
        override_handle=args.handle,
    )

    if args.audit and decision["routing"] is not None:
        _write_audit_from_decision(decision, message)

    enforce_mode = args.enforce
    decision["dry_run"] = not enforce_mode

    print(json.dumps(decision, indent=2))

    if enforce_mode and decision["blocked"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
