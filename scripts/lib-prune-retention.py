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
# Capture safety (DarojaAI/openclaw-gateway#141):
#   The upstream runtime stages one capture tree per plugin-admission
#   event under <stateDir>/tmp/plugin-captures/<instanceId>/ (package
#   copies live in a `captures/` child, and the instance root carries an
#   `owner.sqlite` custody/lease token). Admission on the next load
#   compares file hashes against the bytes captured at admission time, so
#   deleting ANY file out of a still-referenced capture tree (including
#   companion files such as README.md / LICENSE.md) breaks plugin load.
#   This pruner therefore NEVER deletes inside a capture tree that is
#   still referenced. Directories that look like capture instances are
#   treated as atomic units:
#     - a live lease token (owner.sqlite or its -journal/-wal/-shm
#       sidecars present) marks the tree referenced -> skipped + warned;
#     - a token-less tree stays referenced while the installed-plugin
#       registry is non-empty or unreadable -> skipped + warned;
#     - only a token-less tree with a readable registry proving ZERO
#       installed plugins may be pruned, and then only as a whole tree,
#       never file-by-file.
#   Every skipped tree is reported with its reason and counted in the
#   summary (fail-loud). The official repair for a prune-damaged capture
#   is `openclaw doctor` (its plugin phase re-captures plugin trees);
#   `openclaw plugins registry --refresh` does NOT re-capture.
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
#   --state-dir PATH      state dir whose installed-plugin registry gates
#                         token-less capture trees
#                         (env: PRUNE_STATE_DIR; default: $HOME/.openclaw)
#   --capture-aware / --no-capture-aware
#                         enable/disable capture-tree protection for the
#                         target dir. Default: auto — protection is ON
#                         when the target contains capture-instance
#                         directories (owner.sqlite lease family,
#                         captures/ or native/ payload dirs, or legacy
#                         openclaw-plugin-build-* names).
#   --delete              actually delete; without it, dry-run only
#
# Selection order: files/trees older than the age horizon are always
# pruned; if the remaining total still exceeds --max-bytes, the oldest
# survivors are pruned until the cap is met. Both knobs disabled
# (0 / 0) is a no-op.
#
# Exit codes:
#   0  success (including "nothing to prune" / dir missing)
#   1  deletion failed for one or more files (only with --delete)
#   2  usage error (bad/negative knob, no --dir and no PRUNE_DIR)
#
# Output (stdout):
#   one `would delete:` / `deleted:` line per file (or per whole capture
#   tree), oldest first; one `skipped (referenced capture): <dir>
#   (<reason>)` line per protected capture tree; plus a summary line
#   with counts, freed bytes, and skipped-tree totals.

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import sqlite3
import sys
import time
from pathlib import Path

DEFAULT_MAX_AGE_DAYS = 14
DEFAULT_MAX_BYTES = 20 * 1024 ** 3  # 20 GiB

# Upstream plugin-source-capture lease family (see
# src/infra/sqlite-staging-token.ts: SQLITE_STAGING_TOKEN_FILES).
_SQLITE_STAGING_TOKEN_FILES = (
    "owner.sqlite",
    "owner.sqlite-journal",
    "owner.sqlite-wal",
    "owner.sqlite-shm",
)
# Legacy capture instance names (plugin-source-capture-path.ts:
# isLegacyPluginSourceCaptureName).
_LEGACY_CAPTURE_PREFIXES = (
    "openclaw-plugin-build-",
    "openclaw-model-catalog-",
    "openclaw-plugin-captures-",
)

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


# ---------------- capture-instance classification ---------------------------
#
# Capture trees are atomic units owned by the runtime's source-capture
# layer. The lease token (owner.sqlite family) is the durable on-disk
# reference signal; upstream cleanup never removes a tree while a live
# lease exists, and treats unreadable entries, symlinks, and invalid
# tokens as reasons to preserve files ("Live leases, unreadable entries,
# symlinks, and invalid tokens preserve files" — upstream
# src/plugins/plugin-source-capture-directory.ts reclaimInstances).

# Classification outcomes for a capture-instance directory.
PROTECTED_LIVE_LEASE = "live lease"
PROTECTED_AMBIGUOUS_LEASE = "ambiguous lease token"
PROTECTED_INSTALLED = "installed plugins present"
PROTECTED_NO_REGISTRY = "registry unavailable"
PRUNABLE = "prunable"
NOT_CAPTURE = "not a capture instance"


def _is_legacy_capture_name(name: str) -> bool:
    return name.startswith(_LEGACY_CAPTURE_PREFIXES)


def _lease_token_files(directory: Path) -> list[Path]:
    return [directory / name for name in _SQLITE_STAGING_TOKEN_FILES]


def has_capture_instances(root: Path) -> bool:
    """True when the target root contains at least one capture instance."""
    if not root.is_dir():
        return False
    try:
        entries = list(root.iterdir())
    except OSError:
        return False
    return any(entry.is_dir() and looks_like_capture_instance(entry) for entry in entries)


def looks_like_capture_instance(directory: Path) -> bool:
    """Detect runtime capture-instance roots by their on-disk markers."""
    if _is_legacy_capture_name(directory.name):
        return True
    if any(token.exists() or token.is_symlink() for token in _lease_token_files(directory)):
        return True
    if (directory / "captures").is_dir():
        return True
    return (directory / "native").is_dir()


def _parse_installs_json(legacy: Path) -> bool | None:
    try:
        parsed = json.loads(legacy.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(parsed, dict):
        return None
    return parsed == {}


def _parse_installed_index_db(db: Path) -> bool | None:
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute(
                "SELECT install_records_json FROM installed_plugin_index "
                "ORDER BY generated_at_ms DESC LIMIT 1"
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    if row is None:
        return True
    try:
        records = json.loads(row[0])
    except (TypeError, ValueError):
        return None
    if not isinstance(records, dict):
        return None
    return records == {}


def read_installed_plugin_registry(state_dir: Path) -> bool | None:
    """Return True (empty), False (installed plugins present), or None.

    None means the installed-plugin registry cannot be determined
    (missing/malformed/unreadable); callers must then treat every
    token-less capture tree as potentially referenced.
    """
    db = state_dir / "state" / "openclaw-state.sqlite"
    legacy = state_dir / "plugins" / "installs.json"
    if db.is_file():
        status = _parse_installed_index_db(db)
        if status is not None:
            return status
    if legacy.is_file():
        status = _parse_installs_json(legacy)
        if status is not None:
            return status
    return None


def classify_capture_instance(
    directory: Path,
    registry_empty: bool | None,
) -> tuple[str, str | None]:
    """Return (outcome, reason) for one capture-instance directory.

    Outcome is one of the PROTECTED_*/PRUNABLE/NOT_CAPTURE constants;
    reason is the human-readable detail for the skipped line.
    """
    tokens = _lease_token_files(directory)
    present = [token for token in tokens if token.is_symlink() or token.exists()]
    if present:
        if any(token.is_symlink() for token in tokens):
            return PROTECTED_AMBIGUOUS_LEASE, "ambiguous lease token (symlinked)"
        if any(_stat_or_none(token) is None for token in present):
            return PROTECTED_AMBIGUOUS_LEASE, "ambiguous lease token (unreadable)"
        kinds = sorted(str(token.name) for token in present)
        return PROTECTED_LIVE_LEASE, "live lease (" + ", ".join(kinds) + ")"
    if registry_empty is None:
        return PROTECTED_NO_REGISTRY, "installed-plugin registry unavailable"
    if registry_empty is False:
        return PROTECTED_INSTALLED, "installed plugins present (registry non-empty)"
    return PRUNABLE, None


def _tree_stats(directory: Path) -> tuple[int, float, float]:
    """Total regular-file bytes + oldest and newest mtime under a tree.

    Symlinks are never counted (matching the generic pruner). A tree with
    no regular files uses the instance directory's own mtime.
    """
    total = 0
    newest: float | None = None
    oldest: float | None = None
    for dirpath, _dirnames, filenames in os.walk(directory):
        for name in filenames:
            st = _stat_or_none(Path(os.path.join(dirpath, name)))
            if st is None:
                continue
            total += st.st_size
            if newest is None or st.st_mtime > newest:
                newest = st.st_mtime
            if oldest is None or st.st_mtime < oldest:
                oldest = st.st_mtime
    if newest is None:
        entry = _stat_or_none(directory)
        now = float(time.time())
        newest = entry.st_mtime if entry is not None else now
        oldest = newest
    return total, oldest or newest, newest


# ---------------- planning --------------------------------------------------


class PrunePlan:
    """Plan for one run: deletion candidates + skipped capture trees."""

    def __init__(self) -> None:
        self.to_delete: list[tuple[Path, int]] = []
        self.skipped: list[tuple[Path, str]] = []
        self.capture_aware = False


# Lock file this pruner (and sibling pruners) hold during a run: never a
# deletion candidate, even when stale.
_PRUNE_LOCK_NAME = ".prune-retention.lock"


def _collect_loose_files(
    root: Path,
    candidates: list[tuple[Path, int, float, bool]],
) -> None:
    """Collect regular files under a plain (non-capture) subtree."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in filenames:
            if name == _PRUNE_LOCK_NAME:
                continue
            p = Path(os.path.join(dirpath, name))
            if p.is_symlink():
                continue
            st = _stat_or_none(p)
            if st is None:
                continue
            candidates.append((p, st.st_size, st.st_mtime, False))


def plan_prune(
    root: Path,
    max_age_days: int = 0,
    max_bytes: int = 0,
    now_ts: float | None = None,
    state_dir: Path | None = None,
    capture_aware: bool | None = None,
) -> PrunePlan:
    """Return the deletion plan under root, oldest mtime first.

    - Files (or whole capture trees) older than `max_age_days` days
      (when > 0) are always pruned.
    - If total size of the survivors still exceeds `max_bytes` (when
      > 0), the oldest survivors are pruned until the cap is met.
    - Both knobs 0 (or missing dir) -> empty plan.
    - Symlinks are never candidates.
    - Capture trees (auto-detected, or forced via `capture_aware=True`)
      are atomic: a referenced tree is skipped with a reason; only a
      provably-unreferenced tree is deleted whole, never file-by-file.
    """
    plan = PrunePlan()
    if max_age_days <= 0 and max_bytes <= 0:
        return plan
    if not root.is_dir():
        return plan

    effective_capture_aware = (
        has_capture_instances(root) if capture_aware is None else capture_aware
    )
    registry_empty: bool | None = None
    if effective_capture_aware:
        resolved_state = state_dir if state_dir is not None else _default_state_dir()
        registry_empty = read_installed_plugin_registry(resolved_state)

    cutoff_ts = (now_ts if now_ts is not None else time.time()) - max_age_days * 86400

    # (path, size, mtime) for loose files; (path, size, newest, oldest)
    # for whole capture trees.
    candidates: list[tuple[Path, int, float, bool]] = []
    tree_newest: dict[Path, float] = {}

    if effective_capture_aware:
        try:
            children = sorted(root.iterdir(), key=lambda p: p.name)
        except OSError:
            children = []
        for child in children:
            if child.is_symlink():
                continue
            if child.is_dir() and looks_like_capture_instance(child):
                outcome, reason = classify_capture_instance(child, registry_empty)
                if outcome != PRUNABLE:
                    plan.skipped.append((child, reason or "referenced capture"))
                    continue
                tree_bytes, oldest, newest = _tree_stats(child)
                tree_newest[child] = newest
                candidates.append((child, tree_bytes, oldest, True))
                continue
            if child.is_dir():
                _collect_loose_files(child, candidates)
            elif child.is_file():
                st = _stat_or_none(child)
                if st is not None:
                    candidates.append((child, st.st_size, st.st_mtime, False))
    else:
        _collect_loose_files(root, candidates)

    # Oldest first (files by mtime; trees by their oldest entry).
    candidates.sort(key=lambda entry: entry[2])

    to_delete: list[tuple[Path, int]] = []
    survivors: list[tuple[Path, int]] = []
    kept_total = 0
    for path, size, sort_key, is_tree in candidates:
        age_eligible = (
            tree_newest[path] < cutoff_ts if is_tree else sort_key < cutoff_ts
        )
        if max_age_days > 0 and age_eligible:
            to_delete.append((path, size))
            continue
        survivors.append((path, size))
        kept_total += size

    if max_bytes > 0:
        over = kept_total - max_bytes
        for path, size in survivors:
            if over <= 0:
                break
            to_delete.append((path, size))
            over -= size

    plan.to_delete = to_delete
    plan.capture_aware = effective_capture_aware
    return plan


def _default_state_dir() -> Path:
    home = os.environ.get("HOME")
    return Path(home).expanduser() / ".openclaw" if home else Path("/nonexistent-openclaw-state")


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


def _delete_path(p: Path) -> None:
    """Delete a file or a whole (prunable) capture tree."""
    if p.is_dir() and not p.is_symlink():
        shutil.rmtree(p)
    else:
        p.unlink()


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
        "--state-dir",
        help=(
            "state dir whose installed-plugin registry gates token-less "
            "capture trees (env: PRUNE_STATE_DIR; default: $HOME/.openclaw)"
        ),
    )
    parser.add_argument(
        "--capture-aware",
        dest="capture_aware",
        action="store_true",
        default=None,
        help=(
            "protect capture-instance trees (lease/registry check before "
            "deleting; auto-detected when the target contains captures)"
        ),
    )
    parser.add_argument(
        "--no-capture-aware",
        dest="capture_aware",
        action="store_false",
        help="disable capture-tree protection even when captures are detected",
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

    state_dir = args.state_dir or os.environ.get("PRUNE_STATE_DIR")
    root = Path(target).expanduser()
    # Exclusive lock for the whole scan+delete: other pruners (e.g.
    # linux-desktop-seed's prune-openclaw-staging.sh targets the same
    # plugin-captures dir) must not interleave with the plan/apply cycle.
    root.mkdir(parents=True, exist_ok=True)
    lock_path = root / ".prune-retention.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        return _run_locked(
            root,
            max_age_days,
            max_bytes,
            args.delete,
            state_dir,
            args.capture_aware,
        )
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def _run_locked(
    root: Path,
    max_age_days: int,
    max_bytes: int,
    delete: bool,
    state_dir: str | None,
    capture_aware: bool | None,
) -> int:
    plan = plan_prune(
        root,
        max_age_days,
        max_bytes,
        state_dir=Path(state_dir).expanduser() if state_dir else None,
        capture_aware=capture_aware,
    )
    to_delete = plan.to_delete

    mode = "delete" if delete else "dry-run"
    freed = sum(sz for _p, sz in to_delete)

    capture_note = "capture_aware=yes" if plan.capture_aware else "capture_aware=no"
    print(
        f"prune: dir={root} max_age_days={max_age_days} "
        f"max_bytes={fmt_bytes(max_bytes) if max_bytes else 'unlimited'} "
        f"mode={mode} {capture_note}"
    )
    verb = "would delete" if not delete else "deleted"
    for p, _sz in to_delete:
        print(f"{verb}: {p}")
    for p, reason in plan.skipped:
        print(f"skipped (referenced capture): {p} ({reason})")

    skipped_bytes = sum(_tree_stats(p)[0] for p, _reason in plan.skipped)

    detail = ""
    if plan.skipped:
        detail = (
            f"; skipped {len(plan.skipped)} capture tree(s) "
            f"(referenced, {fmt_bytes(skipped_bytes)} retained)"
        )
    if to_delete:
        print(
            f"summary: {len(to_delete)} files {verb}, freeing {fmt_bytes(freed)}{detail}"
        )
    else:
        print(f"summary: nothing to prune{detail}")

    if not delete:
        return 0

    failed = 0
    # Re-check every capture tree right before removal: a lease or an
    # installed-plugin registry that appeared since planning (e.g. the
    # gateway claimed the tree again) must abort the deletion.
    resolved_state = Path(state_dir).expanduser() if state_dir else _default_state_dir()
    registry_empty: bool | None = None
    if plan.capture_aware:
        registry_empty = read_installed_plugin_registry(resolved_state)
    for p, _sz in to_delete:
        if p.is_dir() and not p.is_symlink() and looks_like_capture_instance(p):
            outcome, reason = classify_capture_instance(p, registry_empty)
            if outcome != PRUNABLE:
                print(
                    f"error: refusing to delete capture tree {p} "
                    f"(now referenced: {reason or 'unknown'}); re-run doctor to repair",
                    file=sys.stderr,
                )
                failed += 1
                continue
        try:
            _delete_path(p)
        except OSError as exc:
            failed += 1
            print(f"error: cannot delete {p}: {exc}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())