/**
 * OpenClaw Shared Viz Service — Discord Integration Module
 *
 * Single install at /home/desktopuser/.openclaw/services/viz
 * Usable by ALL agents on this host.
 *
 * Usage from any agent:
 *   const viz = require('/home/desktopuser/.openclaw/services/viz/discord-viz');
 *   const pngPath = await viz.renderMermaid(`graph TD; A-->B`);
 *   // Returns path to PNG, ready for Discord message upload
 */
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const http = require('http');

const VIZ_DIR = path.dirname(__filename);
const CACHE_DIR = process.env.VIZ_CACHE_DIR || path.join(VIZ_DIR, 'cache');
const SERVER_PID_FILE = path.join(VIZ_DIR, '.server.pid');
const HOST = process.env.VIZ_HOST || 'localhost';
const PORT = process.env.VIZ_PORT || 8766;

function ensureCacheDir() {
  if (!fs.existsSync(CACHE_DIR)) fs.mkdirSync(CACHE_DIR, { recursive: true });
}

function isServerRunning() {
  return new Promise((resolve) => {
    const req = http.get(`http://${HOST}:${PORT}/health`, (res) => {
      resolve(res.statusCode === 200);
    });
    req.on('error', () => resolve(false));
    req.setTimeout(2000, () => { req.destroy(); resolve(false); });
  });
}

async function startServer() {
  ensureCacheDir();
  if (await isServerRunning()) return;

  const log = fs.openSync(path.join(VIZ_DIR, 'server.log'), 'a');
  const proc = spawn(process.execPath, ['render-server.js'], {
    cwd: VIZ_DIR,
    detached: true,
    stdio: ['ignore', log, log],
    env: { ...process.env, VIZ_PORT: PORT, VIZ_CACHE_DIR: CACHE_DIR }
  });
  proc.unref();
  fs.writeFileSync(SERVER_PID_FILE, proc.pid.toString());

  for (let i = 0; i < 30; i++) {
    await new Promise(r => setTimeout(r, 500));
    if (await isServerRunning()) return;
  }
  throw new Error('Render server failed to start');
}

async function render(type, source, ext = 'png') {
  await startServer();

  const hash = require('crypto').createHash('sha256').update(source).digest('hex').slice(0, 16);
  const outFile = path.join(CACHE_DIR, `${type}-${hash}.${ext}`);

  if (fs.existsSync(outFile)) return outFile;

  const body = JSON.stringify({ source, type });
  const buf = await new Promise((resolve, reject) => {
    const req = http.request({
      hostname: HOST, port: PORT, path: '/render', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }
    }, (res) => {
      const chunks = [];
      res.on('data', d => chunks.push(d));
      res.on('end', () => {
        if (res.statusCode !== 200) reject(new Error(Buffer.concat(chunks).toString()));
        else resolve(Buffer.concat(chunks));
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });

  fs.writeFileSync(outFile, buf);
  return outFile;
}

async function renderMermaid(source) { return render('mermaid', source, 'png'); }
async function renderGraphviz(source) { return render('graphviz', source, 'png'); }
async function renderChartJS(config) { return render('chartjs', JSON.stringify(config), 'png'); }

async function extractMermaidFromMarkdown(md) {
  const regex = /```mermaid\n([\s\S]*?)\n```/g;
  const matches = [];
  let m;
  while ((m = regex.exec(md)) !== null) matches.push(m[1].trim());
  return matches;
}

async function extractMermaidFromRepo(repoPath, filePattern = '**/*.md') {
  const { glob } = require('glob');
  const files = await glob(filePattern, { cwd: repoPath, absolute: true });
  const results = [];
  for (const f of files) {
    const content = fs.readFileSync(f, 'utf8');
    const diagrams = await extractMermaidFromMarkdown(content);
    for (const d of diagrams) results.push({ file: f, source: d });
  }
  return results;
}

module.exports = {
  VIZ_DIR, CACHE_DIR, PORT, HOST,
  startServer, isServerRunning,
  render, renderMermaid, renderGraphviz, renderChartJS,
  extractMermaidFromMarkdown, extractMermaidFromRepo
};

if (require.main === module) {
  const args = require('minimist')(process.argv.slice(2));
  (async () => {
    let source = args.mermaid || args.graphviz || args.source;
    const type = args.mermaid ? 'mermaid' : args.graphviz ? 'graphviz' : args.type || 'mermaid';
    if (args.file) source = fs.readFileSync(args.file, 'utf8');
    if (!source) {
      console.error(`Usage: node ${path.basename(__filename)} --mermaid "graph TD; A-->B" [--output out.png]
       node ${path.basename(__filename)} --type chartjs --config chart.json --output chart.png`);
      process.exit(1);
    }
    const out = await render(type, source);
    if (args.output) {
      fs.copyFileSync(out, args.output);
      console.log(args.output);
    } else {
      console.log(out);
    }
  })();
}
