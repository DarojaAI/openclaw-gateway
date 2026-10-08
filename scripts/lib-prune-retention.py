#!/usr/bin/env python3
# scripts/lib-prune-retention.py
#
# Bounded-retention pruner for a target directory.
#
# Why: ~/.openclaw/tmp/plugin-captures/ grows unbounded (~1.8 GiB/day
# observed, DarojaAI/openclaw-gateway#134). This script enforces a
# bounded retention policy on any target dir: keep files younger than
# --max-age-days, and keep total size under --max-bytes, deleting
# oldest-first (by mtime) when either knob is exceeded. It is generic
# so it can be pointed at plugin-captures (via the deploy hook or by
# hand) or at any other temp dir the gateway accumulates.
#
# Safety: dry-run is the DEFAULT — it prints what would be deleted and
# deletes nothing. Real deletion requires --delete. Symlinks are never
# touched (only regular files are considered).
#
# Args (CLI flags override env vars, which override defaults):
#   --dir PATH            target directory (env: PRUNE_DIR; required)
#   --max-age-days N      prune files older than N days; 0 = no age cap
#                         (env: PRUNE_MAX_AGE_DAYS; default: 14)
#   --max-bytes SIZE      keep total size <= SIZE; 0 = no size cap.
#                         SIZE accepts K/M/G/T suffixes, e.g. 20G
#                         (env: PRUNE_MAX_BYTES; default: 20G)
#   --delete              actually delete; without it, dry-run only
#
# Selection order: files older than the age horizon are always pruned;
# if the remaining total still exceeds --max-bytes, the oldest
# survivors are pruned until the cap is met. Both knobs disabled
# (0 / 0) is a no-op.
#
# Exit codes:
#   0  success (including "nothing to prune" / dir missing)
#   1  deletion failed for one or more files (only with --delete)
#   2  usage error (bad/negative knob, no --dir and no PRUNE_DIR)
#
# Output (stdout):
#   one `would delete:` / `deleted:` line per file, oldest first,
#   plus a summary line with file count and freed bytes.

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path

DEFAULT_MAX_AGE_DAYS = 14
DEFAULT_MAX_BYTES = 20 * 1024 ** 3  # 20 GiB

_SIZE_SUFFIXES = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}
_SIZE_RE = re.compile(r"^\s*(\d+)\s*([kKmMgGtT]?)\s*$")


def parse_size(text: str) -> int:
    """Parse a byte count with optional K/M/G/T suffix (case-insensitive).

    Plain integers (no suffix) are bytes. Raises ValueError on junk.
    """
    m = _SIZE_RE.match(text)
    if not m:
        raise ValueError(f"invalid size {text!r} (expected bytes, optionally with K/M/G/T suffix)")
    return int(m.group(1)) * _SIZE_SUFFIXES[m.group(2).upper()]


def fmt_bytes(n: int) -> str:
    """Human-readable byte count, e.g. 1048576 -> '1.0 MiB'."""
    value = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(value) < 1024 or unit == "TiB":
            return f"{int(value)} B" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{int(n)} B"  # unreachable; keeps type checkers happy


def _stat_or_none(p: Path) -> os.stat_result | None:
    """One stat for mtime+size; None if the entry vanished mid-walk."""
    try:
        return p.stat()
    except OSError:
        return None


def plan_prune(
    root: Path,
    max_age_days: int = 0,
    max_bytes: int = 0,
    now_ts: float | None = None,
) -> list[tuple[Path, int]]:
    """Return (path, size) pairs to delete under root, oldest mtime first.

    - Files older than `max_age_days` days (when > 0) are always pruned.
    - If total size of the survivors still exceeds `max_bytes` (when
      > 0), the oldest survivors are pruned until the cap is met.
    - Both knobs 0 (or missing dir) -> empty list.
    - Only regular files are considered; symlinks and directories are
      never candidates.
    """
    if max_age_days <= 0 and max_bytes <= 0:
        return []
    if not root.is_dir():
        return []

    cutoff_ts = (now_ts if now_ts is not None else time.time()) - max_age_days * 86400

    entries: list[tuple[Path, os.stat_result]] = []
    for p in root.rglob("*"):
        if p.is_symlink() or not p.is_file():
            continue
        st = _stat_or_none(p)
        if st is None:
            continue
        entries.append((p, st))
    entries.sort(key=lambda e: e[1].st_mtime)

    to_delete: list[tuple[Path, int]] = []
    survivors: list[tuple[Path, os.stat_result]] = []
    kept_total = 0
    for p, st in entries:
        if max_age_days > 0 and st.st_mtime < cutoff_ts:
            to_delete.append((p, st.st_size))
        else:
            survivors.append((p, st))
            kept_total += st.st_size

    if max_bytes > 0:
        over = kept_total - max_bytes
        for p, st in survivors:
            if over <= 0:
                break
            to_delete.append((p, st.st_size))
            over -= st.st_size

    return to_delete


def _resolve_int(flag_val: int | None, env_name: str, default: int) -> int:
    if flag_val is not None:
        return flag_val
    raw = os.environ.get(env_name)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        print(f"error: {env_name} must be an integer, got {raw!r}", file=sys.stderr)
        raise SystemExit(2)


def _resolve_size(flag_val: int | None, env_name: str, default: int) -> int:
    if flag_val is not None:
        return flag_val
    raw = os.environ.get(env_name)
    if raw is None or raw == "":
        return default
    try:
        return parse_size(raw)
    except ValueError as exc:
        print(f"error: {env_name}: {exc}", file=sys.stderr)
        raise SystemExit(2)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Bounded-retention pruner: delete files in a target dir "
            "oldest-first until age and size caps are met. Dry-run by "
            "default; pass --delete to actually remove files."
        )
    )
    parser.add_argument(
        "--dir",
        help="target directory to prune (env: PRUNE_DIR; required)",
    )
    parser.add_argument(
        "--max-age-days",
        type=int,
        help=(
            "prune files older than N days; 0 = no age cap "
            f"(env: PRUNE_MAX_AGE_DAYS; default: {DEFAULT_MAX_AGE_DAYS})"
        ),
    )
    parser.add_argument(
        "--max-bytes",
        type=parse_size,
        help=(
            "keep total size at or below SIZE (K/M/G/T suffixes ok); "
            "0 = no size cap (env: PRUNE_MAX_BYTES; "
            f"default: {fmt_bytes(DEFAULT_MAX_BYTES)})"
        ),
    )
    parser.add_argument(
        "--delete",
        action="store_true",
        help="actually delete files (default is dry-run: print only)",
    )
    args = parser.parse_args()

    target = args.dir or os.environ.get("PRUNE_DIR")
    if not target:
        parser.error("--dir is required (or set PRUNE_DIR)")

    max_age_days = _resolve_int(args.max_age_days, "PRUNE_MAX_AGE_DAYS", DEFAULT_MAX_AGE_DAYS)
    max_bytes = _resolve_size(args.max_bytes, "PRUNE_MAX_BYTES", DEFAULT_MAX_BYTES)

    if max_age_days < 0 or max_bytes < 0:
        print("error: --max-age-days and --max-bytes must be >= 0", file=sys.stderr)
        return 2

    if max_age_days == 0 and max_bytes == 0:
        print("no pruning knobs enabled (max-age-days=0 and max-bytes=0): nothing to do")
        return 0

    root = Path(target).expanduser()
    to_delete = plan_prune(root, max_age_days, max_bytes)

    mode = "delete" if args.delete else "dry-run"
    freed = sum(sz for _p, sz in to_delete)

    print(
        f"prune: dir={root} max_age_days={max_age_days} "
        f"max_bytes={fmt_bytes(max_bytes) if max_bytes else 'unlimited'} "
        f"mode={mode}"
    )
    verb = "would delete" if not args.delete else "deleted"
    for p, _sz in to_delete:
        print(f"{verb}: {p}")

    if to_delete:
        print(
            f"summary: {len(to_delete)} files {verb}, freeing {fmt_bytes(freed)}"
        )
    else:
        print("summary: nothing to prune")

    if not args.delete:
        return 0

    failed = 0
    for p, _sz in to_delete:
        try:
            p.unlink()
        except OSError as exc:
            failed += 1
            print(f"error: cannot delete {p}: {exc}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())