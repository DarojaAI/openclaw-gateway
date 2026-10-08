# AGENTS.md - OpenClaw Gateway

**Project:** OpenClaw Gateway — Discord AI agent platform

## Scope

This repo is Layer 3b in the infrastructure stack:
- Layer 1: [`terraform-hcloud-linux-vm`](https://github.com/DarojaAI/terraform-hcloud-linux-vm) (bare VM)
- Layer 2: [`linux-desktop-setup`](https://github.com/DarojaAI/linux-desktop-setup) (desktop environment)
- Layer 3a: [`linux-desktop-seed`](https://github.com/DarojaAI/linux-desktop-seed) (VM ops + deploy orchestration)
- **Layer 3b: openclaw-gateway (this repo)**

## What Belongs Here

- OpenClaw configuration (`config/openclaw-defaults.json`, `config/openclaw-test-vm.json`)
- Discord skills (`config/skills/`)
- Shared services used by multiple agents (`config/services/`)
- OpenClaw installation and config scripts (`scripts/install/`)
- Model management tools (`scripts/openclaw-model-manager.py`)
- Cost monitoring (`scripts/cost-monitor.py`)
- Discord diagnostics and bridge scripts
- OpenClaw config schema validation

## What Does NOT Belong Here

- VM provisioning (Layer 1 → [`terraform-hcloud-linux-vm`](https://github.com/DarojaAI/terraform-hcloud-linux-vm))
- Desktop environment setup (Layer 2 → [`linux-desktop-setup`](https://github.com/DarojaAI/linux-desktop-setup))
- VM maintenance scripts (Layer 3a → [`linux-desktop-seed`](https://github.com/DarojaAI/linux-desktop-seed))
- Session monitoring (Layer 3a → [`linux-desktop-seed`](https://github.com/DarojaAI/linux-desktop-seed))
- Backup/security scripts (Layer 3a → [`linux-desktop-seed`](https://github.com/DarojaAI/linux-desktop-seed))

## Deploy Flow

1. [`linux-desktop-seed`](https://github.com/DarojaAI/linux-desktop-seed) deploys VM and clones this repo to `/tmp/openclaw-gateway`
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

# Upstream (openclaw/openclaw) filing hygiene

Learned 2026-10-08 after withdrawing two premature filings (#167495, #167496):

- **Verify the mechanism in the installed runtime's code before filing.** Symptoms (journal lines, DB sizes) are evidence of state, not of cause. Never attribute a defect to a specific code path without reading that path — grep `dist/` (or a source checkout) for the claimed behavior first.
- **Re-verify at every escalation of the claim.** The PR-prep code read caught a bad filing that the filing-time check missed (#167495). Each stage that strengthens the claim (comment → filing → fix proposal → PR) needs fresh evidence for the mechanism, not just the symptom.
- **Issue bodies and incident postmortems are claims, not evidence.** Re-derive every causal claim independently before restating it in a public tracker.
- **Search for prior art first.** Several defect families (e.g. plugin-capture staging growth) already have multiple open reports; duplicates add noise.
- **Check ecosystem tooling before blaming the runtime.** Scripts in this repo and `linux-desktop-seed` write gateway state directly and unvalidated (e.g. `scripts/openclaw-model-manager.py` used to dump the whole `openclaw.json` with legacy `agents.list`). Many "openclaw bugs" are our tooling.
- **Use the issue templates** (`bug_report.yml`, `feature_request.yml`): `[Bug]:`/`[Feature]:` title prefix, structured fields, version/OS, grounded repro; features and design changes route through the feature form or Discord first.
