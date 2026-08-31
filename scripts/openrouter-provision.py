#!/usr/bin/env python3
"""OpenRouter provisioning CLI for per-agent API keys.

Provisions, lists, and revokes OpenRouter API keys on a per-agent
basis, using a single master (provisioning) key for authentication.
Each provisioned child key is created with a per-agent USD spend
limit and a monthly reset, so the OpenRouter dashboard can attribute
spend to the calling agent and enforce a hard ceiling on each one.

The ``sync`` subcommand is the deploy-time entry point: the seed
repo's ``configure-openclaw-agent.sh`` invokes it with the comma-
separated list of agent ids it knows about, and the script emits
one JSON line per newly-provisioned agent on stdout. Already-
provisioned agents (matched by ``label``) are left alone, so
re-running ``sync`` is idempotent.

All HTTP is done with ``urllib.request`` from the standard library,
so the script runs on the target VM without a pip install.

The provisioning key is read from the ``OPENROUTER_PROVISIONING_KEY``
environment variable. The script never logs, echoes, or persists the
key — only the per-agent child keys it provisions, which the caller
is expected to write into ``~/.openclaw/agents/<id>/agent/auth-profiles.json``.

Subcommands
-----------
- ``provision --agent <id> [--limit <usd>] [--reset monthly] [--dry-run]``
- ``list``
- ``info --key <sk-or-…>``
- ``revoke --hash <hash>``
- ``sync --agents <comma-separated> [--dry-run]``

Environment
-----------
- ``OPENROUTER_PROVISIONING_KEY``  (required)  master key for POST/GET/DELETE
- ``OPENROUTER_API_BASE``          (optional)  override base URL (default https://openrouter.ai/api/v1)
- ``OPENROUTER_DEFAULT_AGENT_LIMIT`` (optional) USD per agent, default 10
- ``OPENROUTER_DEFAULT_AGENT_RESET`` (optional) "monthly" or "weekly"/"daily", default "monthly"
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

# Default OpenRouter provisioning API base. The /keys endpoints accept
# POST/GET/DELETE on /api/v1/keys, and the child-key self-info endpoint
# lives at /api/v1/key (singular). Both are documented at
# https://openrouter.ai/docs/api-reference/api-keys.
DEFAULT_API_BASE = "https://openrouter.ai/api/v1"
DEFAULT_AGENT_LIMIT = 10.0
DEFAULT_AGENT_RESET = "monthly"
HTTP_TIMEOUT_SECONDS = 30.0


# ── pure helpers (unit-testable, no network) ────────────────────────


def build_create_body(
    agent_id: str,
    limit: float,
    reset: str,
    *,
    include_byok_in_limit: bool = True,
) -> dict[str, Any]:
    """Build the JSON body for ``POST /api/v1/keys``.

    Pure function so tests can assert its shape without any HTTP.
    ``include_byok_in_limit`` defaults to True so BYOK traffic counts
    against the per-agent cap (consistent with the cost-monitor
    attribution model: every dollar the agent causes should count
    against its limit).
    """
    if not agent_id:
        raise ValueError("agent_id must be non-empty")
    if limit <= 0:
        raise ValueError("limit must be > 0")
    if reset not in {"monthly", "weekly", "daily"}:
        raise ValueError(f"unsupported reset value: {reset!r}")
    body: dict[str, Any] = {
        "name": agent_id,
        "limit": limit,
        "limit_reset": reset,
        "include_byok_in_limit": include_byok_in_limit,
    }
    return body


def _is_masked_key(value: str) -> bool:
    """Detect OpenRouter's UI-style masked key string.

    Real OpenRouter child keys start with ``sk-or-v1-``. Masked keys from
    the API responses (whether in POST bodies, GET list payloads, or
    log-redacted forms) start with ``sk-or-…`` (Unicode U+2026 + suffix).
    A masked key is truthy but un-extractable; we treat it as missing
    so the calling code falls back to the GET /keys reconciliation path.
    """
    if not isinstance(value, str):
        return False
    return value.startswith("sk-or-\u2026")


def parse_list_response(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Normalize the ``GET /api/v1/keys`` response.

    The OpenRouter API returns ``{"data": [...]}`` where each entry
    carries ``hash``, ``label``, ``limit``, ``limit_reset``, and
    ``usage_monthly`` (with ``usage`` being the lifetime spend).

    ``name`` is the key's human-readable name — which is what
    ``build_create_body`` sets to ``agent_id`` — while ``label`` on
    API-created keys is often the masked key string itself
    (``sk-or-v1-0e6...1c96``, per the OpenRouter /keys schema example).
    Prefer ``name`` for matching so per-agent keys surface under their
    agent id; fall back to ``label`` for keys created in the dashboard.
    """
    data = payload.get("data")
    if not isinstance(data, list):
        raise ValueError("unexpected /keys response shape: 'data' is not a list")
    normalized: list[dict[str, Any]] = []
    for entry in data:
        if not isinstance(entry, dict):
            continue
        normalized.append(
            {
                "hash": entry.get("hash", ""),
                # name first: our create body sets name=agent_id; the
                # API's label field on API-created keys is the masked
                # key string. Dashboard-created keys carry a friendly
                # label, so fall back to it.
                "label": entry.get("name") or entry.get("label", ""),
                "name": entry.get("name", "") or entry.get("label", ""),
                "limit": entry.get("limit"),
                "limit_reset": entry.get("limit_reset"),
                "usage": entry.get("usage"),
                "usage_monthly": entry.get("usage_monthly"),
            }
        )
    return normalized


def format_list_tsv(rows: list[dict[str, Any]]) -> str:
    """Render the list output as TSV with a header row.

    Easier to ``awk``/``column -t`` than JSON when humans are looking
    at the output of ``openrouter-provision list`` on a VM. A field
    that is ``None`` or absent renders as an empty string; a numeric
    zero (e.g. ``usage_monthly = 0.0``) renders as ``"0.0"`` — we
    do not want to treat ``0`` the same as missing, which is what
    ``row.get(col) or ""`` would do.
    """
    header = ["hash", "label", "limit", "limit_reset", "usage_monthly"]
    lines = ["\t".join(header)]
    for row in rows:
        cells: list[str] = []
        for col in header:
            value = row.get(col)
            cells.append("" if value is None else str(value))
        lines.append("\t".join(cells))
    return "\n".join(lines) + "\n"


def split_agent_csv(csv_value: str) -> list[str]:
    """Split a comma-separated agent list, trimming whitespace and
    dropping empty entries. Rejects any entry that is empty after
    trim, but does not enforce agent-id syntax — the seed and
    gateway agree on naming, and over-strict validation here would
    just push the failure to the API call."""
    if not csv_value:
        return []
    out: list[str] = []
    for piece in csv_value.split(","):
        piece = piece.strip()
        if piece:
            out.append(piece)
    return out


def find_existing_key(
    rows: list[dict[str, Any]], agent_id: str
) -> dict[str, Any] | None:
    """Return the first row whose label/name matches ``agent_id``."""
    for row in rows:
        if row.get("label") == agent_id or row.get("name") == agent_id:
            return row
    return None


# ── HTTP layer ──────────────────────────────────────────────────────


class ProvisioningError(RuntimeError):
    """Raised when the OpenRouter API returns a non-2xx response, or
    when the response body cannot be decoded. The original HTTP body
    is preserved on ``.body`` and the status code on ``.status`` so
    callers (and tests) can assert on them."""

    def __init__(self, message: str, *, status: int | None = None, body: str = ""):
        super().__init__(message)
        self.status = status
        self.body = body


def _request(
    method: str,
    url: str,
    *,
    provisioning_key: str,
    body: dict[str, Any] | None = None,
    auth_key: str | None = None,
) -> dict[str, Any]:
    """Issue a single HTTP request and return the decoded JSON.

    ``auth_key``, when set, overrides the bearer token — used by the
    ``info`` subcommand, which authenticates with a child key rather
    than the master provisioning key. ``body`` is JSON-encoded when
    supplied.
    """
    data: bytes | None = None
    headers = {
        "Accept": "application/json",
        "User-Agent": "openclaw-gateway/openrouter-provision/1.0",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    bearer = auth_key if auth_key is not None else provisioning_key
    headers["Authorization"] = f"Bearer {bearer}"

    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as resp:
            raw = resp.read().decode("utf-8")
            status = resp.status
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        raise ProvisioningError(
            f"OpenRouter API {method} {url} failed: HTTP {exc.code}",
            status=exc.code,
            body=raw,
        ) from exc
    except urllib.error.URLError as exc:
        raise ProvisioningError(
            f"OpenRouter API {method} {url} failed: {exc.reason}"
        ) from exc

    if not (200 <= status < 300):
        raise ProvisioningError(
            f"OpenRouter API {method} {url} failed: HTTP {status}",
            status=status,
            body=raw,
        )
    try:
        return json.loads(raw) if raw else {}
    except json.JSONDecodeError as exc:
        raise ProvisioningError(
            f"OpenRouter API {method} {url} returned non-JSON: {exc.msg}",
            status=status,
            body=raw,
        ) from exc


def list_keys(
    *, provisioning_key: str, api_base: str = DEFAULT_API_BASE
) -> list[dict[str, Any]]:
    """Return the normalized list of every key under this account.

    OpenRouter's ``GET /api/v1/keys`` caps the response at the server-side
    page size (~100 keys). On an account with many keys (the org hit
    ~529 keys on 2026-08-31 with a single-page cap), a single
    unparameterized request misses the majority of keys — agents with
    only late-page rows appear as ``missing`` in callers that depend on
    full coverage (e.g. the post-deploy per-agent provisioning gate in
    linux-desktop-seed, which checks that every agent in ``agents.list``
    has at least one child key with limit+limit_reset). Paginate
    transparently here so every caller of ``list_keys`` sees a
    complete inventory.

    The pagination contract is: ``?limit=N&offset=M`` returns at most N
    keys starting at offset M. We loop with N=100 and M=0,100,200,...
    until a short page (less than N entries) signals the tail. The
    loop is bounded by an absolute ceiling so a misbehaving server
    that always returns N entries can't infinite-loop the deploy.
    """
    base = api_base.rstrip("/")
    page_size = 100
    offset = 0
    normalized: list[dict[str, Any]] = []
    max_pages = 100  # 100 pages * 100 keys/page = 10000 keys max
    for _ in range(max_pages):
        url = f"{base}/keys?limit={page_size}&offset={offset}"
        payload = _request("GET", url, provisioning_key=provisioning_key)
        page = parse_list_response(payload)
        normalized.extend(page)
        if len(page) < page_size:
            break
        offset += page_size
    return normalized


def create_key(
    *,
    agent_id: str,
    limit: float,
    reset: str,
    provisioning_key: str,
    api_base: str = DEFAULT_API_BASE,
    include_byok_in_limit: bool = True,
) -> dict[str, Any]:
    """Provision a new child key. The response ``data`` block carries
    the key string under ``key`` exactly once; persist it
    immediately. ``label`` is the agent id."""
    url = f"{api_base.rstrip('/')}/keys"
    body = build_create_body(
        agent_id, limit, reset, include_byok_in_limit=include_byok_in_limit
    )
    payload = _request("POST", url, provisioning_key=provisioning_key, body=body)
    data = payload.get("data")
    # OpenRouter's actual ``POST /keys`` success shape is
    # ``{"data": {...metadata...}, "key": "sk-or-v1-..."}`` — the
    # key lives at the **top level** of the payload, NOT under
    # ``data.key``. ``data.get("key")`` was empty on the deploy
    # run 33140981754 (2026-08-28T04:13:25Z, both provision calls
    # returning valid ``sk-or-v1-…`` strings at top-level only).
    # Read top-level first, then fall back to ``data.get("key")`` and
    # finally reconcile via list_keys with the agent ``name``. The
    # _is_masked_key guard is preserved: real keys start with
    # ``sk-or-v1-``; masked keys start with ``sk-or-…`` (Unicode
    # U+2026 horizontal ellipsis). Refs: deploy 31846911941 (legacy
    # masked-key shape); deploy 33140981754 (current top-level-shape).
    top_level_key = payload.get("key") if isinstance(payload, dict) else None
    data_nested_key = data.get("key") if isinstance(data, dict) else None
    if isinstance(top_level_key, str) and top_level_key and not _is_masked_key(top_level_key):
        # Lift the top-level key into the data block so all downstream
        # reconciliation paths see a unified shape.
        if isinstance(data, dict):
            data.setdefault("key", top_level_key)
        else:
            data = {"key": top_level_key}
        return data
    raw_key = data_nested_key
    if isinstance(data, dict) and raw_key and not _is_masked_key(raw_key):
        return data
    # POST succeeded (HTTP 200) but the response shape didn't carry an
    # extractable ``data.key`` (either the field is missing, empty, or
    # masked). In all three cases the key WAS created server-side —
    # HTTP 200 confirms the create. Recover by listing keys and matching
    # on ``name`` (which build_create_body sets to ``agent_id``).
    raise_on_unrecoverable = True
    try:
        listed = list_keys(provisioning_key=provisioning_key, api_base=api_base)
    except (ProvisioningError, ValueError):
        # Reconciliation is best-effort. ProvisioningError fires when the
        # GET transport fails; ValueError fires when parse_list_response
        # rejects a non-list 'data' field (e.g. 404 with empty body).
        # Either way, fall through to ``listed=[]`` so the second guard
        # ("no list entry matches") gets a chance to fire instead of
        # crashing the deploy on an uncaught exception.
        listed = []
        raise_on_unrecoverable = False
    if not listed and raise_on_unrecoverable:
        raise ProvisioningError(
            "POST /keys returned a non-extractable body and the subsequent "
            "GET /keys reconciliation came back empty. The key may not have "
            "been created server-side; refusing to fabricate auth profile.",
            status=200,
            body=json.dumps(payload),
        )
    matched = next(
        (
            entry for entry in listed
            if (
                entry.get("label") == agent_id
                or entry.get("name") == agent_id
            ) or (
                entry.get("hash") and isinstance(data, dict)
                and data.get("hash") == entry.get("hash")
            )
        ),
        None,
    )
    # parse_list_response collapses 'name' into 'label' (with a
    # masked fragment fallback) on listed entries. If we didn't
    # match by either of the names above, re-query the raw
    # endpoint with full entry shape and retry matching on a name
    # field directly. This is a structural redundancy that
    # _is_masked_key makes necessary. Refs: deploy 33140981754.
    # Note: keep this fenced off the happy path to avoid the cost
    # on routine dispatches.
    if matched is None:
        try:
            raw_listed = _request(
                "GET", f"{api_base.rstrip('/')}/keys",
                provisioning_key=provisioning_key
            ).get("data") or []
        except (ProvisioningError, ValueError, urllib.error.URLError):
            raw_listed = []
        matched = next(
            (
                entry for entry in raw_listed
                if isinstance(entry, dict)
                and (
                    entry.get("name") == agent_id
                    or entry.get("label") == agent_id
                )
            ),
            None,
        )
    if matched is None:
        raise ProvisioningError(
            f"POST /keys reconciliation: no list entry matches agent_id={agent_id!r} "
            f"or hash={data.get('hash') if isinstance(data, dict) else None!r}",
            status=200,
            body=json.dumps(payload),
        )


def revoke_key(
    *,
    key_hash: str,
    provisioning_key: str,
    api_base: str = DEFAULT_API_BASE,
) -> None:
    """Delete a child key by its hash (NOT the key string)."""
    if not key_hash:
        raise ValueError("key_hash must be non-empty")
    url = f"{api_base.rstrip('/')}/keys/{key_hash}"
    _request("DELETE", url, provisioning_key=provisioning_key)


def key_info(
    *, child_key: str, api_base: str = DEFAULT_API_BASE
) -> dict[str, Any]:
    """Fetch the per-key info for a child key (limit, usage, etc.).

    Auth is the child key, not the master provisioning key — the
    /api/v1/key endpoint is the child-key "self view".
    """
    url = f"{api_base.rstrip('/')}/key"
    payload = _request("GET", url, provisioning_key="", auth_key=child_key)
    data = payload.get("data")
    if not isinstance(data, dict):
        raise ProvisioningError(
            "GET /key response missing data block",
            status=200,
            body=json.dumps(payload),
        )
    return data


# ── command implementations ────────────────────────────────────────


def _require_provisioning_key() -> str:
    key = os.environ.get("OPENROUTER_PROVISIONING_KEY", "").strip()
    if not key:
        sys.stderr.write(
            "ERROR: OPENROUTER_PROVISIONING_KEY is not set. Export it or "
            "pass it via the systemd override at "
            "/home/desktopuser/.config/systemd/user/openclaw-gateway.service.d/override.conf.\n"
        )
        raise SystemExit(2)
    return key


def cmd_provision(args: argparse.Namespace) -> int:
    """Provision a single child key for one agent. Idempotent on label."""
    provisioning_key = _require_provisioning_key()
    api_base = os.environ.get("OPENROUTER_API_BASE", DEFAULT_API_BASE)
    limit = float(args.limit) if args.limit is not None else float(
        os.environ.get("OPENROUTER_DEFAULT_AGENT_LIMIT", DEFAULT_AGENT_LIMIT)
    )
    reset = args.reset or os.environ.get(
        "OPENROUTER_DEFAULT_AGENT_RESET", DEFAULT_AGENT_RESET
    )
    body = build_create_body(args.agent, limit, reset)

    if args.dry_run:
        sys.stdout.write(
            json.dumps(
                {
                    "dry_run": True,
                    "method": "POST",
                    "url": f"{api_base.rstrip('/')}/keys",
                    "body": body,
                }
            )
            + "\n"
        )
        return 0

    try:
        existing = list_keys(provisioning_key=provisioning_key, api_base=api_base)
    except (ProvisioningError, ValueError):
        # The pre-check list_keys() call is best-effort. If the GET
        # endpoint misbehaves or returns a non-list payload (e.g.,
        # the mock-surface 404 with empty body), treat it as "no
        # existing keys" and let the POST /keys call attempt to
        # create the agent key. create_key() will surface any
        # subsequent unrecoverable failure via its own broader
        # try/except + reconciliation guard. Refs: deploy 31846911941.
        existing = []
    match = find_existing_key(existing, args.agent)
    if match is not None:
        sys.stderr.write(
            f"Refusing to re-provision: a key with label={args.agent!r} "
            f"already exists (hash={match.get('hash')!r}, limit={match.get('limit')!r}). "
            "OpenRouter does not expose a rotate-by-label endpoint; revoke the "
            "existing key with `revoke --hash <hash>` first if you need a new one.\n"
        )
        sys.stdout.write(
            json.dumps({"existed": True, "label": args.agent, "key": match}) + "\n"
        )
        return 0

    data = create_key(
        agent_id=args.agent,
        limit=limit,
        reset=reset,
        provisioning_key=provisioning_key,
        api_base=api_base,
    )
    sys.stdout.write(json.dumps({"existed": False, "label": args.agent, "key": data}) + "\n")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    """List every child key under this provisioning account as TSV."""
    provisioning_key = _require_provisioning_key()
    api_base = os.environ.get("OPENROUTER_API_BASE", DEFAULT_API_BASE)
    rows = list_keys(provisioning_key=provisioning_key, api_base=api_base)
    sys.stdout.write(format_list_tsv(rows))
    return 0


def cmd_info(args: argparse.Namespace) -> int:
    """Print the /key self-view for a child key as JSON."""
    if not args.key:
        sys.stderr.write("ERROR: --key <sk-or-…> is required\n")
        return 2
    api_base = os.environ.get("OPENROUTER_API_BASE", DEFAULT_API_BASE)
    data = key_info(child_key=args.key, api_base=api_base)
    sys.stdout.write(json.dumps(data, indent=2) + "\n")
    return 0


def cmd_revoke(args: argparse.Namespace) -> int:
    """Delete a child key by its hash."""
    if not args.hash:
        sys.stderr.write("ERROR: --hash <hash> is required\n")
        return 2
    provisioning_key = _require_provisioning_key()
    api_base = os.environ.get("OPENROUTER_API_BASE", DEFAULT_API_BASE)
    revoke_key(key_hash=args.hash, provisioning_key=provisioning_key, api_base=api_base)
    sys.stdout.write(
        json.dumps({"revoked": True, "hash": args.hash}) + "\n"
    )
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    """Provision any missing child keys for the given agent list.

    Emits one JSONL line per newly-provisioned agent on stdout (so the
    caller can capture each key string and write it into the agent's
    ``auth-profiles.json``). Already-provisioned agents are skipped
    silently — the caller is expected to look at the agent's own
    ``auth-profiles.json`` for the key material, not at the sync
    output. The TSV summary of skipped agents is written to stderr
    for humans tailing the deploy log.
    """
    provisioning_key = _require_provisioning_key() if not args.dry_run else ""
    api_base = os.environ.get("OPENROUTER_API_BASE", DEFAULT_API_BASE)
    limit = float(
        os.environ.get("OPENROUTER_DEFAULT_AGENT_LIMIT", DEFAULT_AGENT_LIMIT)
    )
    reset = os.environ.get("OPENROUTER_DEFAULT_AGENT_RESET", DEFAULT_AGENT_RESET)
    agents = split_agent_csv(args.agents)
    if not agents:
        sys.stderr.write("ERROR: --agents <comma-separated> is required and must list at least one agent\n")
        return 2

    if args.dry_run:
        for agent in agents:
            body = build_create_body(agent, limit, reset)
            sys.stdout.write(
                json.dumps(
                    {
                        "dry_run": True,
                        "method": "POST",
                        "url": f"{api_base.rstrip('/')}/keys",
                        "body": body,
                    }
                )
                + "\n"
            )
        return 0

    existing = list_keys(provisioning_key=provisioning_key, api_base=api_base)
    skipped: list[str] = []
    for agent in agents:
        if find_existing_key(existing, agent) is not None:
            skipped.append(agent)
            continue
        data = create_key(
            agent_id=agent,
            limit=limit,
            reset=reset,
            provisioning_key=provisioning_key,
            api_base=api_base,
        )
        sys.stdout.write(
            json.dumps({"agent": agent, "key": data.get("key"), "data": data}) + "\n"
        )

    if skipped:
        sys.stderr.write(
            f"sync: skipped {len(skipped)} already-provisioned agent(s): "
            f"{', '.join(skipped)}\n"
        )
    return 0


# ── CLI plumbing ───────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    """Build the argparse tree. Kept in one place so the ``--help``
    text stays the authoritative reference for the deploy scripts."""
    parser = argparse.ArgumentParser(
        prog="openrouter-provision",
        description=(
            "Provision, list, and revoke per-agent OpenRouter API keys "
            "using a single master provisioning key."
        ),
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    p_provision = sub.add_parser(
        "provision",
        help="Create a child key for one agent (idempotent on label).",
    )
    p_provision.add_argument("--agent", required=True, help="Agent id (becomes the key label)")
    p_provision.add_argument(
        "--limit",
        type=float,
        default=None,
        help="Per-agent USD spend limit (default: $OPENROUTER_DEFAULT_AGENT_LIMIT or 10)",
    )
    p_provision.add_argument(
        "--reset",
        choices=("monthly", "weekly", "daily"),
        default=None,
        help="Reset cadence (default: monthly)",
    )
    p_provision.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the POST body that would be sent, do not call the API",
    )
    p_provision.set_defaults(func=cmd_provision)

    p_list = sub.add_parser("list", help="List every child key under this account (TSV)")
    p_list.set_defaults(func=cmd_list)

    p_info = sub.add_parser(
        "info",
        help="Fetch the per-key self-view (limit/usage) for a child key",
    )
    p_info.add_argument("--key", required=True, help="Child key string, e.g. sk-or-…")
    p_info.set_defaults(func=cmd_info)

    p_revoke = sub.add_parser("revoke", help="Delete a child key by its hash")
    p_revoke.add_argument("--hash", required=True, help="Key hash from `list` (NOT the key string)")
    p_revoke.set_defaults(func=cmd_revoke)

    p_sync = sub.add_parser(
        "sync",
        help="Provision any missing child keys for a comma-separated agent list",
    )
    p_sync.add_argument(
        "--agents",
        required=True,
        help="Comma-separated agent ids to ensure keys for",
    )
    p_sync.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the POST bodies that would be sent, do not call the API",
    )
    p_sync.set_defaults(func=cmd_sync)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ProvisioningError as exc:
        sys.stderr.write(f"ERROR: {exc}\n")
        if exc.body:
            sys.stderr.write(f"--- response body ({exc.status}) ---\n{exc.body}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
