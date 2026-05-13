# AGENTS.md - OpenClaw Gateway

**Project:** OpenClaw Gateway — Discord AI agent platform

## Scope

This repo is Layer 3b in the infrastructure stack:
- Layer 1: terraform-hcloud-linux-vm (bare VM)
- Layer 2: linux-desktop-setup (desktop environment)
- Layer 3a: linux-desktop-seed (VM ops + deploy orchestration)
- **Layer 3b: openclaw-gateway (this repo)**

## What Belongs Here

- OpenClaw configuration (`config/openclaw-defaults.json`, `config/openclaw-test-vm.json`)
- Discord skills (`config/skills/`)
- OpenClaw installation and config scripts (`scripts/install/`)
- Model management tools (`scripts/openclaw-model-manager.py`)
- Cost monitoring (`scripts/cost-monitor.py`)
- Discord diagnostics and bridge scripts
- OpenClaw config schema validation

## What Does NOT Belong Here

- VM provisioning (Layer 1 → terraform-hcloud-linux-vm)
- Desktop environment setup (Layer 2 → linux-desktop-setup)
- VM maintenance scripts (Layer 3a → linux-desktop-seed)
- Session monitoring (Layer 3a → linux-desktop-seed)
- Backup/security scripts (Layer 3a → linux-desktop-seed)

## Deploy Flow

1. `linux-desktop-seed` deploys VM and clones this repo to `/tmp/openclaw-gateway`
2. `scripts/install/deploy.sh` is called to install config, skills, and scripts
3. OpenClaw gateway service is restarted

## Validation

```bash
# Python syntax
python3 -m py_compile scripts/*.py scripts/install/*.py

# Bash syntax
bash -n scripts/*.sh scripts/install/*.sh scripts/remote/*.sh

# Config schema
python3 scripts/merge-openclaw-config.py --validate
```
