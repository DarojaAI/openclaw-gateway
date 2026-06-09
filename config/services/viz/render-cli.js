#!/usr/bin/env node
/**
 * CLI wrapper for the viz render server.
 * Usage:
 *   node render-cli.js --type mermaid --input file.mmd --output out.png
 *   echo "graph TD; A-->B" | node render-cli.js --type mermaid --output out.png
 */
const fs = require('fs');
const http = require('http');
const path = require('path');

const PORT = process.env.VIZ_PORT || 8765;
const HOST = process.env.VIZ_HOST || 'localhost';

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = { type: 'mermaid' };
  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--type': opts.type = args[++i]; break;
      case '--input': opts.input = args[++i]; break;
      case '--output': opts.output = args[++i]; break;
      case '--config': opts.config = args[++i]; break;
      case '--source': opts.source = args[++i]; break;
      default:
        if (!opts.source && !args[i].startsWith('--')) opts.source = args[i];
    }
  }
  return opts;
}

function render(opts) {
  return new Promise((resolve, reject) => {
    let source = opts.source;
    if (opts.input) source = fs.readFileSync(opts.input, 'utf8');
    if (!source) {
      // Read from stdin
      const chunks = [];
      process.stdin.on('data', d => chunks.push(d));
      process.stdin.on('end', () => {
        const src = Buffer.concat(chunks).toString('utf8');
        doRender({ ...opts, source: src }).then(resolve).catch(reject);
      });
      return;
    }
    doRender(opts).then(resolve).catch(reject);
  });
}

function doRender(opts) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      source: opts.source,
      type: opts.type,
      config: opts.config ? JSON.parse(fs.readFileSync(opts.config, 'utf8')) : undefined
    });

    const req = http.request({
      hostname: HOST,
      port: PORT,
      path: '/render',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body)
      }
    }, (res) => {
      const chunks = [];
      res.on('data', d => chunks.push(d));
      res.on('end', () => {
        const buf = Buffer.concat(chunks);
        if (res.statusCode !== 200) {
          reject(new Error(`HTTP ${res.statusCode}: ${buf.toString()}`));
          return;
        }
        if (opts.output) {
          fs.writeFileSync(opts.output, buf);
          console.log(`Wrote ${buf.length} bytes to ${opts.output}`);
        } else {
          process.stdout.write(buf);
        }
        resolve(buf);
      });
    });

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

const opts = parseArgs();
if (!opts.source && !opts.input && process.stdin.isTTY) {
  console.error(`Usage: node render-cli.js [--type mermaid|graphviz|chartjs] --input <file> --output <file>
       echo "graph TD; A-->B" | node render-cli.js --output out.png`);
  process.exit(1);
}

render(opts).catch(err => {
  console.error(err.message);
  process.exit(1);
});
