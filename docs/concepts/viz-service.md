# Viz Service — Reference

The viz render service is a **shared service** that lives in `openclaw-gateway` and is deployed once per host. It is accessible to all OpenClaw agents (including this one) via:

```
/home/desktopuser/.openclaw/services/viz/discord-viz.js
```

The service is automatically deployed by `openclaw-gateway/scripts/install/deploy.sh` (step 5).

## Usage from This Agent

```javascript
const viz = require('/home/desktopuser/.openclaw/services/viz/discord-viz');
const pngPath = await viz.renderMermaid(`graph TD; A-->B`);
```

Or via the auto-discovered skill at `~/.openclaw/skills/viz/SKILL.md`.

## Server

- Port: `8766` (override with `VIZ_PORT`)
- Auto-starts on first render call
- Caches by content hash

## Source / Truth

Source of truth is `DarojaAI/openclaw-gateway`:
- `config/services/viz/` — service code
- `config/skills/viz/SKILL.md` — skill registration
- `scripts/services/install-viz-service.sh` — installer

To redeploy after upstream changes:
```bash
bash /home/desktopuser/.openclaw/services/viz/../  # or rerun gateway deploy
```

## What Doesn't Belong Here

The actual service code is **not** duplicated in this repo. Only this reference doc lives here in `openclaw-gateway/docs/concepts/`. The canonical source is in `openclaw-gateway` (Layer 3b).
