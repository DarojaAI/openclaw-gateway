---
name: add-mcp-server
description: "Wire a new MCP server into OpenClaw via the contract-driven deploy pipeline. Add a server or troubleshoot reachability."
---

# Add MCP Server

Wire a new MCP (Model Context Protocol) server into OpenClaw through the `linux-desktop-seed` deploy pipeline. The contract-driven design means adding server #N is **one config entry + two `gh` commands + one PR**, not a code change.

## When to use

- "Add the GitHub MCP server"
- "Wire up the Slack MCP tools"
- "I want trip_planning to be able to call <server>"
- "Duffel isn't reachable from the gateway" (troubleshooting)
- "Add another MCP server" / "another mcp server to the list"

## Architecture (read this once)

There are **two repos** involved:

| Repo | Role | What it owns |
|------|------|--------------|
| `linux-desktop-seed` (L3a) | Deploy pipeline, VM ops, config merge | The contract map (`dat-contract.yaml` `mcp_servers`), the Pydantic contract (`workflow_contract.py`), the runner-side token handoff (`copy-deploy-artifacts.sh` phase 11), the schema, the plaintext-secret gate, the VM-side merge step that resolves `source: "file"` SecretRefs |
| `openclaw-gateway` (L3b) | Runtime: OpenClaw binary, agents, skills | The runtime that consumes `mcp.servers` and connects to the servers at startup. **No per-server config lives here.** |

The token round-trip is: GitHub env secret → runner `env:` block (env var, not argv) → mktemp runner-side file → scp → VM-side `install -m 0600 -o desktopuser` at `token_file` path → merge step reads file → live `~/.openclaw/openclaw.json` has the bearer inline. The token **never** appears in the repo, the ideal config, the runner stdout, or any argv.

## Step-by-step

For a server named `<name>` (e.g. `duffel`, `github`, `slack`):

### 1. Edit `config/dat-contract.yaml` in `linux-desktop-seed`

Append an entry to the `mcp_servers:` map (alphabetical order is not required; new entries go at the bottom of the map). Required fields:

```yaml
mcp_servers:
  <name>:
    description: "Human-readable summary (deploy log only)"
    transport: streamable-http          # streamable-http | sse (stdio is not yet wired)
    url_var: OPENCLAW_<NAME>_URL         # env var name that holds the per-env URL
    token_var: MCP_TOKEN_<NAME>          # env var name that holds the per-env bearer
    token_file: "/etc/openclaw/secrets/<name>-mcp.token"   # VM-side path
    required_in:                         # which envs need this server
      - prod                             # e.g. [prod] or [test, head, prod] or [] for optional
    enabled: true
    tools: []                            # future per-tool scope; leave empty unless restricting
```

**Naming convention for env vars:**
- URL: `OPENCLAW_<NAME>_URL` (uppercased server name with hyphens → underscores)
- Secret: `MCP_TOKEN_<NAME>` (same convention)
- Token file: `/etc/openclaw/secrets/<name>-mcp.token` (kebab-case server name)

### 2. Edit `config/workflow_contract.py` in `linux-desktop-seed`

Add two fields to the `HetznerEnvironment` Pydantic class. The deploy-time workflow-contract validator (`scripts/ci/validate-workflow-contract.py`) will fail CI if these don't appear in `deploy.yml`'s `env:` block, and vice versa.

```python
openclaw_<name>_url: str = Field(
    default="",
    description="<Name> MCP server URL (per-env, e.g. https://api.example.com/mcp)",
)
mcp_token_<name>: str = Field(
    default="",
    description="<Name> MCP bearer token (per-env secret)",
)
```

### 3. Edit `.github/workflows/deploy.yml` in `linux-desktop-seed`

In the **"Copy L3-only files (maintenance scripts)"** step, add two lines to the `env:` block (one var, one secret). Mirror the existing `OPENCLAW_DUFFEL_URL` / `MCP_TOKEN_DUFFEL` pair as the template.

```yaml
        env:
          # ... existing ...
          OPENCLAW_<NAME>_URL: ${{ vars.OPENCLAW_<NAME>_URL }}
          MCP_TOKEN_<NAME>: ${{ secrets.MCP_TOKEN_<NAME> }}
```

**No other deploy.yml changes are needed.** The contract-driven loop in `copy-deploy-artifacts.sh` phase 11 picks up the new entry automatically from `dat-contract.yaml`.

### 4. Set the GitHub environment var + secret (user action, outside the PR)

For each env listed in `required_in:`:

```bash
gh variable set OPENCLAW_<NAME>_URL --env <env>     # e.g. http://89.167.4.143:8765/mcp
gh secret set MCP_TOKEN_<NAME> --env <env>          # paste the bearer token
```

- The var and secret are **environment-scoped** (not repo/org-scoped). Set them in GitHub repo Settings → Environments → `<env>` → Variables and Secrets.
- If `required_in: [prod]`, set them only in prod. Other envs see an empty mcp.servers block and the server is not wired.

### 5. Validation chain (run before pushing)

```bash
cd linux-desktop-seed

# 1. Schema + config consistency
./scripts/validate-data-contracts.sh

# 2. Workflow contract (var/secret names match deploy.yml)
python3 scripts/ci/validate-workflow-contract.py

# 3. Plaintext-secret gate
python3 scripts/ci/check-no-plaintext-secrets.py config/openclaw-ideal-config.json
# Generate a real candidate and re-run:
OPENCLAW_ENV=prod \
  OPENCLAW_DISCORD_GUILD_ID=1 OPENCLAW_DISCORD_CHANNEL_ID=2 \
  OPENCLAW_DISCORD_ALLOWED_USER=user:3 DISCORD_BOT_TOKEN=t OPENROUTER_API_KEY=k \
  OPENCLAW_<NAME>_URL=https://example.com/mcp MCP_TOKEN_<NAME>=t \
  python3 scripts/ci/generate-openclaw-env-overrides.py
# (it writes to /tmp/env-overrides.json, owned by root in some sandboxes; cp to a writable path)
python3 scripts/ci/check-no-plaintext-secrets.py /tmp/env-overrides.json

# 4. BATS
bats tests/check-no-plaintext-secrets.bats tests/file-secretref.bats

# 5. ShellCheck on changed files
shellcheck scripts/ci/copy-deploy-artifacts.sh scripts/ci/generate-openclaw-env-overrides.py
```

### 6. Open the PR

```bash
git checkout -b feat/mcp-<name>-server
git add config/dat-contract.yaml config/workflow_contract.py .github/workflows/deploy.yml CHANGELOG.md
git commit -m "feat(mcp): wire <name> MCP server (prod)"
gh pr create --title "feat(mcp): wire <name> MCP server" --body "..."
```

After the PR merges, `release-please` will open a release PR that bumps VERSION. Merge the release PR; the tag is created; **then** trigger `deploy.yml` against `environment: prod` (or whichever env has the secrets set).

## Troubleshooting

### Server not reachable after deploy

1. **Check the merged config on the VM.** SSH to the VM, then:
   ```bash
   sudo jq '.mcp.servers' /home/desktopuser/.openclaw/openclaw.json
   ```
   The server should appear with a real `headers.Authorization` string (not a SecretRef dict). If the value is `{"source": "file", ...}`, the merge step's file resolution failed.

2. **Check the token file on the VM.**
   ```bash
   sudo ls -la /etc/openclaw/secrets/<name>-mcp.token
   sudo cat /etc/openclaw/secrets/<name>-mcp.token     # should be non-empty
   ```
   If the file is missing, the runner's phase 11 didn't stage it. Check that `MCP_TOKEN_<NAME>` is set in the GitHub env's secrets tab.

3. **Check the env var on the runner.** Look at the deploy run's "Copy L3-only files" step; the `MCP_TOKEN_<NAME>: ${{ secrets.MCP_TOKEN_<NAME> }}` line should appear in the env block. If the secret is unset in the GitHub env, the runner logs `mcp_servers.<name>: <token_var> unset (required_in includes <env>); deploy will fail`.

4. **Test the server directly from the VM.**
   ```bash
   TOKEN=$(sudo cat /etc/openclaw/secrets/<name>-mcp.token)
   curl -sS -w "\n%{http_code}\n" -H "Authorization: Bearer $TOKEN" https://example.com/mcp
   ```
   Should return 200 with a JSON-RPC initialize response.

### Plaintext-secret gate failing

The gate (run in CI) checks `/tmp/openclaw-env-merged.json` (the runner-side merged candidate). If it complains about `mcp.servers.<name>.headers.Authorization`:

- A plaintext bearer landed at that path. Almost always means the contract entry is malformed and the env-overrides step is emitting a string instead of a SecretRef dict.
- Re-check `dat-contract.yaml` for the entry: `url_var` and `token_var` must be strings, not absent.

### File-SecretRef resolution aborts on the VM

The merge step (`scripts/remote/merge-openclaw-config.py`) reads `source: "file"` SecretRefs and inlines the bytes. It fails the merge (exit 1) on:
- File missing
- File empty
- File unreadable (EACCES — check ownership: should be `desktopuser:desktopuser`, mode 0600)

Look at the merge step's stderr output on the VM:
```bash
sudo journalctl -u openclaw-gateway.service --since "10 minutes ago" | grep -A 5 "file SecretRef"
```

## What this skill does NOT do

- **Per-agent / per-tool scope.** Today's `mcp.servers.<name>` is host-wide. The schema exposes `mcp.servers.<name>.codex.agents` (Codex projection) and `toolFilter.include/exclude` for narrowing, but per-agent MCP opt-out is not generally available. If a server has a dangerous write action (e.g. `book_flight`), consider:
  - Adding `tools: ["<safe-tools-only>"]` to the contract's `toolFilter.include` to expose only read-only tools
  - Setting `codex.agents: ["<agent-id>"]` in the merged server entry (Codex-specific)
  - Accepting the host-wide blast radius (default; matches the duffel guidance)
- **stdio transport.** The schema allows it but the runner-side loop assumes HTTP-style transports with a URL. stdio servers would need additional plumbing for the `command` + `args` + `env` fields.
- **OAuth flows.** `source: "oauth"` is a separate SecretRef variant. Not currently used in any wired server; the `mcp.servers.<name>.oauth` block in the schema is the right hook when needed.

## Reference

- PR: linux-desktop-seed#887 (introduced the contract-driven MCP server wiring; this skill lives in the companion PR `openclaw-gateway` that adds the `add-mcp-server` skill itself)
- Schema: `linux-desktop-seed/schemas/openclaw-config.schema.json` — `mcp.servers.<name>` definition
- Plaintext-secret gate: `linux-desktop-seed/scripts/ci/check-no-plaintext-secrets.py` — wildcard for `mcp.servers.*.headers.Authorization`
- File SecretRef resolver: `linux-desktop-seed/scripts/remote/merge-openclaw-config.py` — `resolve_file_secretrefs` function
- Token handoff: `linux-desktop-seed/scripts/ci/copy-deploy-artifacts.sh` — phase 11
