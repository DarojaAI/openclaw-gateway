---
name: viz
description: "Render Mermaid, Graphviz, and Chart.js diagrams to PNG for Discord, Slack, or any image-consuming surface. Use when the user asks to visualize a diagram, render a mermaid block from a repo, or show a chart. Backend is a shared Playwright service at /home/desktopuser/.openclaw/services/viz."
---

# OpenClaw Shared Viz Service

Shared visualization service for all OpenClaw agents on this host.

## When to Use

- User asks to render a mermaid / flowchart / sequence diagram / chart
- User wants a diagram from a markdown file or git repo visualized
- Any task needing `graph TD; A-->B`-style text → PNG

## Quick Start

```javascript
// From any agent workspace:
const viz = require('/home/desktopuser/.openclaw/services/viz/discord-viz');
const pngPath = await viz.renderMermaid(`graph TD; A-->B`);
// pngPath is a file path — attach to a Discord message or include in output
```

## Render Types

| Type | Function | Input |
|------|----------|-------|
| Mermaid | `viz.renderMermaid(source)` | Mermaid syntax string |
| Graphviz | `viz.renderGraphviz(dot)` | DOT language string |
| Chart.js | `viz.renderChartJS(config)` | Chart.js config object |

## Scanning Repos for Mermaid

```javascript
const diagrams = await viz.extractMermaidFromRepo('/path/to/repo');
// Returns: [{ file: 'docs/arch.md', source: 'graph TD...' }, ...]
for (const d of diagrams) {
  const png = await viz.renderMermaid(d.source);
  // post to discord...
}
```

## Server

The render server auto-starts on first call. To start manually:

```bash
node /home/desktopuser/.openclaw/services/viz/render-server.js
```

Server config:
- Port: `8766` (override with `VIZ_PORT`)
- Cache: `/home/desktopuser/.openclaw/services/viz/cache` (override with `VIZ_CACHE_DIR`)
- Health: `GET /health`

## Posting to Discord

After rendering, the PNG path is ready for the OpenClaw message tool:

```javascript
const pngPath = await viz.renderMermaid(source);
// Use the message tool with media: pngPath
```

Discord supports PNG up to 8MB natively. Larger diagrams auto-fit because we screenshot the rendered DOM element.

## Notes

- Renders are cached by content hash, so identical diagrams are instant
- Uses Playwright + Chromium (no Puppeteer)
- First request per session has ~2s cold-start cost (browser launch)
- Supports mermaid v11, graphviz via @hpcc-js/wasm, Chart.js v4
