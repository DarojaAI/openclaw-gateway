# Skills Management

## Overview

OpenClaw skills are reusable procedures that help the agent handle specific tasks through structured workflows. This document covers the skill lifecycle: creation, testing, deployment, and maintenance.

## Architecture

**Source of Truth:** `openclaw-gateway/config/skills/`

Skills in this directory are canonical and deployed to all VMs running OpenClaw. Each skill is a self-contained directory with:

```
config/skills/
├── model-management/
│   ├── SKILL.md              # Main skill definition (required)
│   ├── scripts/              # Optional helper scripts
│   ├── references/           # Optional reference docs
│   └── examples/             # Optional usage examples
```

## Skill File Structure

### SKILL.md (required)

Every skill must have a `SKILL.md` file with front matter:

```markdown
---
name: skill-name
description: Brief description for skill matching
trigger: "/command" | "always"
---

# Skill Title

Detailed skill instructions for the agent...
```

**Front Matter Fields:**
- `name` — kebab-case identifier
- `description` — Used for skill matching (keep under 160 chars)
- `trigger` — Slash command (`"/model"`), keyword phrase, or `"always"` for auto-load

## Canonical Skills

The following skills are maintained in this repo and deployed to all VMs:

| Skill | Description | Trigger |
|-------|-------------|---------|
| `atlas` | Database schema management with Atlas CLI | Atlas migrations, schema diff |
| `git-extras` | Extended Git operations (rebase, bisect, stash) | Git rebase, squash, cleanup |
| `maintenance` | VM maintenance commands | `/restart`, `/connect`, `/status` |
| `model-management` | Model discovery, switching, cost tracking | `/model`, `/model-switch` |
| `model-preferences` | Model defaults for all roles | Model preferences |
| `session-commands` | Session control | `/reset`, `/compact`, `/stop` |
| `viz` | Diagram rendering (Mermaid, Graphviz, Chart.js) | Visualize diagrams |

## Skill Lifecycle

### 1. Create a Skill

Create a new skill directory in `config/skills/`:

```bash
mkdir -p config/skills/my-skill
```

Write `SKILL.md` with front matter + instructions:

```markdown
---
name: my-skill
description: What this skill does
trigger: "/mycommand"
---

# My Skill

When the user runs `/mycommand`:
1. Do this
2. Then that
3. Return result
```

### 2. Test Locally

Deploy the skill to your local `~/.openclaw/skills/`:

```bash
rsync -av config/skills/my-skill/ ~/.openclaw/skills/my-skill/
```

Restart the gateway:

```bash
systemctl --user restart openclaw-gateway.service
```

Test the trigger and verify behavior.

### 3. Commit to Repo

Once tested:

```bash
git add config/skills/my-skill/
git commit -m "feat(skills): add my-skill for X"
git push origin main
```

### 4. Deploy to VMs

Skills are deployed during the standard deploy pipeline. The deploy workflow:

1. Checks out `openclaw-gateway` repo
2. Copies `config/skills/*` to the target VM's `~/.openclaw/skills/`
3. Restarts the gateway to load new skills

**Manual deploy** (if needed):

```bash
ssh target-vm
cd ~/GithubProjects/openclaw-gateway
git pull
rsync -av config/skills/ ~/.openclaw/skills/
systemctl --user restart openclaw-gateway.service
```

## Skill Updates

To update an existing skill:

1. Edit `config/skills/<skill-name>/SKILL.md`
2. Test locally (rsync + restart)
3. Commit and push
4. Deploy follows standard pipeline (or manual sync)

## File Permissions

- **Markdown/config files:** `644` (rw-r--r--)
- **Executable scripts:** `755` (rwxr-xr-x)

Set automatically during sync:

```bash
find config/skills -type f -name "*.md" -exec chmod 644 {} \;
find config/skills -type f -name "*.sh" -exec chmod 755 {} \;
```

## Backend Scripts

Some skills rely on backend scripts installed system-wide. These live in `scripts/` and are deployed to `/usr/local/bin/`:

| Script | Purpose | Used By |
|--------|---------|---------|
| `openclaw-model-manager` | Model management CLI | `model-management` skill |
| `cost-monitor.py` | Cost tracking | `cost-report` skill |
| `openclaw-catalog-sync.py` | OpenRouter catalog sync | `model-management` skill |

**Deploy backend scripts:**

```bash
sudo cp scripts/openclaw-model-manager /usr/local/bin/
sudo chmod 755 /usr/local/bin/openclaw-model-manager
```

## Skill Discovery

OpenClaw loads skills from two locations:

1. **Built-in skills:** `/usr/lib/node_modules/openclaw/skills/` (shipped with the package)
2. **User skills:** `~/.openclaw/skills/` (custom/override skills)

User skills override built-in skills with the same name.

**List loaded skills:**

```bash
openclaw skills list
```

## Troubleshooting

### Skill not loading

1. Check front matter syntax in `SKILL.md`
2. Restart gateway: `systemctl --user restart openclaw-gateway.service`
3. Check logs: `journalctl --user -u openclaw-gateway -f`

### Skill trigger not matching

- Ensure `trigger` in front matter matches expected command or keyword
- Check skill description length (keep under 160 chars for matching)

### Permission errors

- Verify `SKILL.md` is `644`: `chmod 644 config/skills/*/SKILL.md`
- Verify scripts are `755`: `chmod 755 scripts/*`

## Best Practices

1. **Keep skills focused** — One skill, one responsibility
2. **Test before commit** — Always test locally first
3. **Document triggers clearly** — Use descriptive front matter
4. **Version control everything** — Commit skills to the repo, not just local
5. **Avoid hardcoded paths** — Use `~/` or relative paths in skill instructions

## See Also

- [AGENTS.md](../AGENTS.md) — Agent behavioral contract
- [README.md](../README.md) — Repo overview
- [scripts/](../scripts/) — Backend script implementations
