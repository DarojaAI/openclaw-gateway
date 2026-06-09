/**
 * OpenClaw Viz Render Server
 * HTTP endpoint: POST /render
 * Body: { source: "mermaid/graphviz/chartjs text", type: "mermaid" }
 * Returns: PNG image buffer
 */
const express = require('express');
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const app = express();
app.use(express.json({ limit: '2mb' }));

const PORT = process.env.VIZ_PORT || 8766;
const CACHE_DIR = process.env.VIZ_CACHE_DIR || path.join(__dirname, 'cache');
const BROWSER_WS = process.env.PLAYWRIGHT_WS_ENDPOINT || null;

if (!fs.existsSync(CACHE_DIR)) fs.mkdirSync(CACHE_DIR, { recursive: true });

let browser = null;
let browserContext = null;

async function getBrowser() {
  if (browser) return browser;
  const launchOpts = {
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
  };
  if (BROWSER_WS) {
    browser = await chromium.connect(BROWSER_WS);
  } else {
    browser = await chromium.launch(launchOpts);
  }
  browserContext = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  return browser;
}

async function renderMermaid(source) {
  const hash = crypto.createHash('sha256').update(source).digest('hex').slice(0, 16);
  const cachePath = path.join(CACHE_DIR, `mermaid-${hash}.png`);

  if (fs.existsSync(cachePath)) {
    return fs.readFileSync(cachePath);
  }

  await getBrowser();
  const page = await browserContext.newPage();

  const html = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
  <style>
    body { margin: 0; padding: 20px; background: white; }
    #container { display: inline-block; }
  </style>
</head>
<body>
  <div id="container" class="mermaid">${source.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</div>
  <script>
    mermaid.initialize({ startOnLoad: true, theme: 'default' });
  </script>
</body>
</html>`;

  await page.setContent(html, { waitUntil: 'networkidle' });
  await page.waitForSelector('.mermaid svg', { timeout: 15000 });
  // Wait a tick for rendering to settle
  await page.waitForTimeout(500);

  const container = await page.$('#container');
  const buffer = await container.screenshot({ type: 'png' });
  await page.close();

  fs.writeFileSync(cachePath, buffer);
  return buffer;
}

async function renderGraphviz(source) {
  const hash = crypto.createHash('sha256').update(source).digest('hex').slice(0, 16);
  const cachePath = path.join(CACHE_DIR, `graphviz-${hash}.png`);

  if (fs.existsSync(cachePath)) {
    return fs.readFileSync(cachePath);
  }

  await getBrowser();
  const page = await browserContext.newPage();

  const html = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <script src="https://unpkg.com/@hpcc-js/wasm@2.20.0/dist/graphviz.umd.js"></script>
  <style>
    body { margin: 0; padding: 20px; background: white; }
    #container { display: inline-block; }
  </style>
</head>
<body>
  <div id="container"></div>
  <script>
    const hpccWasm = window["@hpcc-js/wasm"];
    hpccWasm.graphviz.layout(${JSON.stringify(source)}, "svg", "dot")
      .then(svg => {
        document.getElementById('container').innerHTML = svg;
      });
  </script>
</body>
</html>`;

  await page.setContent(html, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const container = await page.$('#container');
  const buffer = await container.screenshot({ type: 'png' });
  await page.close();

  fs.writeFileSync(cachePath, buffer);
  return buffer;
}

async function renderChartJS(config) {
  const hash = crypto.createHash('sha256').update(JSON.stringify(config)).digest('hex').slice(0, 16);
  const cachePath = path.join(CACHE_DIR, `chartjs-${hash}.png`);

  if (fs.existsSync(cachePath)) {
    return fs.readFileSync(cachePath);
  }

  await getBrowser();
  const page = await browserContext.newPage();

  const html = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
  <style>
    body { margin: 0; padding: 20px; background: white; }
    #container { width: 600px; height: 400px; }
  </style>
</head>
<body>
  <div id="container"><canvas id="chart"></canvas></div>
  <script>
    const ctx = document.getElementById('chart').getContext('2d');
    new Chart(ctx, ${JSON.stringify(config)});
  </script>
</body>
</html>`;

  await page.setContent(html, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const container = await page.$('#container');
  const buffer = await container.screenshot({ type: 'png' });
  await page.close();

  fs.writeFileSync(cachePath, buffer);
  return buffer;
}

app.post('/render', async (req, res) => {
  try {
    const { source, type = 'mermaid', config } = req.body;
    if (!source && !config) {
      return res.status(400).json({ error: 'Missing source or config' });
    }

    let buffer;
    switch (type) {
      case 'mermaid':
        buffer = await renderMermaid(source);
        break;
      case 'graphviz':
        buffer = await renderGraphviz(source);
        break;
      case 'chartjs':
        buffer = await renderChartJS(config || JSON.parse(source));
        break;
      default:
        return res.status(400).json({ error: `Unknown type: ${type}` });
    }

    res.set('Content-Type', 'image/png');
    res.set('X-Render-Type', type);
    res.set('X-Render-Size', buffer.length.toString());
    res.send(buffer);
  } catch (err) {
    console.error('Render error:', err);
    res.status(500).json({ error: err.message, stack: err.stack });
  }
});

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', browser: browser ? 'connected' : 'not_started' });
});

app.post('/shutdown', async (_req, res) => {
  res.json({ status: 'shutting_down' });
  if (browser) await browser.close();
  process.exit(0);
});

const server = app.listen(PORT, () => {
  console.log(`Viz render server listening on http://localhost:${PORT}`);
});

process.on('SIGINT', async () => {
  if (browser) await browser.close();
  server.close(() => process.exit(0));
});
process.on('SIGTERM', async () => {
  if (browser) await browser.close();
  server.close(() => process.exit(0));
});
