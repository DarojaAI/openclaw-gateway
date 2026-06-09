# OpenClaw Shared Viz Service

Renders Mermaid, Graphviz, and Chart.js diagrams to PNG. Shared across all OpenClaw agents on this host.

## Location

`/home/desktopuser/.openclaw/services/viz/`

## Architecture

```
┌─────────────────┐     HTTP POST /render      ┌──────────────────┐
│  Any OpenClaw   │ ─────────────────────────> │  render-server   │
│  agent          │  {source, type: mermaid}   │  (Playwright)    │
│                 │ <───────────────────────── │  Port 8766       │
│                 │      PNG image buffer       └──────────────────┘
└─────────────────┘
```

## Components

| File | Purpose |
|------|---------|
| `render-server.js` | Express server, Playwright browser, render engines |
| `render-cli.js` | CLI for local rendering (pipes or files) |
| `discord-viz.js` | Node module — auto-starts server, renders to cache |

## Supported Types

- `mermaid` - Mermaid diagrams (flowcharts, sequence, class, gantt, etc.)
- `graphviz` - DOT/Graphviz diagrams
- `chartjs` - Chart.js configs

## Usage

### From Any Agent

```javascript
const viz = require('/home/desktopuser/.openclaw/services/viz/discord-viz');
const pngPath = await viz.renderMermaid(`graph TD; A-->B`);
```

### CLI

```bash
# Render mermaid from string
node /home/desktopuser/.openclaw/services/viz/discord-viz.js --mermaid "graph TD; A-->B" --output out.png

# Render from file
node /home/desktopuser/.openclaw/services/viz/render-cli.js --input diagram.mmd --output out.png

# Render from stdin
echo "graph TD; A-->B" | node /home/desktopuser/.openclaw/services/viz/render-cli.js --output out.png
```

### HTTP API

```bash
node -e "
const http = require('http');
const data = JSON.stringify({type:'mermaid',source:'graph TD\n  A-->B'});
const req = http.request({hostname:'localhost', port:8766, path:'/render', method:'POST', headers:{'Content-Type':'application/json','Content-Length':data.length}}, res => {
  const chunks = [];
  res.on('data', d => chunks.push(d));
  res.on('end', () => {
    require('fs').writeFileSync('out.png', Buffer.concat(chunks));
    console.log('saved', Buffer.concat(chunks).length, 'bytes');
  });
});
req.write(data);
req.end();
"
```

## Environment Variables

| Var | Default | Description |
|-----|---------|-------------|
| `VIZ_PORT` | `8766` | Server port |
| `VIZ_CACHE_DIR` | `./cache` | Cache directory for rendered images |
| `VIZ_HOST` | `localhost` | Server hostname |
| `PLAYWRIGHT_WS_ENDPOINT` | `null` | Connect to existing browser instead of launching |

## Auto-Start

`discord-viz.js` automatically starts the server if it's not running. To start manually:

```bash
node /home/desktopuser/.openclaw/services/viz/render-server.js
```

## Skill Registration

The skill is registered at `/home/desktopuser/.openclaw/skills/viz/SKILL.md` so all OpenClaw agents discover it.

## Setup / Reinstall

```bash
cd /home/desktopuser/.openclaw/services/viz
npm install
node render-server.js &
```

## Bot Access

This service is accessible to ALL OpenClaw agents on this host:
- `linux_desktop_seed`
- `trip_planning`
- `dev_nexus`
- `dev_nexus_frontend`
- `research_orchestrator`
- `core_business_management`
- ... and the rest

Each agent can `require()` the module and render diagrams independently.
