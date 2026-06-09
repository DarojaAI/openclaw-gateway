# OpenClaw Gateway

Discord AI agent platform built on [OpenClaw](https://openclaw.ai). Deployed as Layer 3b on top of `linux-desktop-setup` VMs.

## What This Is

This repo contains everything needed to run a Discord-connected AI coding agent:
- OpenClaw configuration and skills
- Model management (switching, cost tracking, discovery)
- Discord guild/channel binding automation
- Cost monitoring and context health tracking

## Architecture

```
Layer 1: terraform-hcloud-linux-vm  -> Bare VM
Layer 2: linux-desktop-setup        -> Desktop + dev tools
Layer 3a: linux-desktop-seed        -> VM ops + deploy orchestration
Layer 3b: openclaw-gateway (this)   -> Discord AI agent platform
```

## Quick Start

On a VM with OpenClaw already installed via `linux-desktop-seed`:

```bash
git clone https://github.com/DarojaAI/openclaw-gateway.git /tmp/openclaw-gateway
cd /tmp/openclaw-gateway
bash scripts/install/deploy.sh
```

## Key Components

| Component | Purpose |
|-----------|---------|
| `config/skills/` | Discord-integrated skills (model management, maintenance, session commands, viz) |
| `config/services/viz/` | Shared mermaid/graphviz/chartjs render service (deployed to `~/.openclaw/services/viz/`) |
| `scripts/openclaw-model-manager.py` | Model discovery, switching, cost tracking |
| `scripts/cost-monitor.py` | Per-model usage and cost breakdown |
| `scripts/openclaw-bind-repos.sh` | Auto-bind Discord channels to repos |
| `scripts/install/config.sh` | Deploy OpenClaw config to `~/.openclaw/` |

## Model Management

```bash
# List models with badges
openclaw-model-manager list --free-only --sort cost

# Switch default model
openclaw-model-manager switch burns

# Check usage
openclaw-model-manager cost --days 7
```

## Development

- Skills live in `config/skills/`
- Run `python3 -m py_compile scripts/*.py` before committing
- Run `bash -n scripts/**/*.sh` before committing
