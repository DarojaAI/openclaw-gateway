'use strict';

/**
 * Discord-bound response adapter for OpenClaw agents.
 *
 * Drop-in `require()` module. Auto-starts the normalizer server if it isn't
 * already running, then routes calls to /normalize.
 *
 * Mirrors the shape of services/viz/discord-viz.js so the gateway's outbound
 * path can adopt it with minimal ceremony.
 *
 * Usage from any agent workspace:
 *
 *   const normalize = require('/home/desktopuser/.openclaw/services/discord-response-normalizer/discord-normalize');
 *   const result = await normalize.formatReply({
 *     agent_id: 'linux_desktop_seed',
 *     text: agentReplyText,
 *   });
 *   for (const chunk of result.chunks) {
 *     await discordChannel.send({ content: chunk, username: result.username, avatar_url: result.avatar_url });
 *   }
 */

const http = require('http');
const path = require('path');
const { spawn } = require('child_process');

const PORT = parseInt(process.env.NORMALIZER_PORT || '8767', 10);
const HOST = process.env.NORMALIZER_HOST || 'localhost';
const SERVICE_PATH = path.resolve(__dirname);

let serverStartedHere = false;
let serverStartPromise = null;

function postJson(payload) {
  return new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify(payload), 'utf8');
    const req = http.request(
      {
        hostname: HOST,
        port: PORT,
        path: '/normalize',
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': data.length,
        },
      },
      (res) => {
        const chunks = [];
        res.on('data', (d) => chunks.push(d));
        res.on('end', () => {
          const body = Buffer.concat(chunks).toString('utf8');
          if (res.statusCode !== 200) {
            reject(new Error('HTTP ' + res.statusCode + ': ' + body));
            return;
          }
          try {
            resolve(JSON.parse(body));
          } catch (e) {
            reject(new Error('invalid JSON from server: ' + e.message));
          }
        });
      }
    );
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

function ensureServer() {
  if (serverStartPromise) return serverStartPromise;
  serverStartPromise = new Promise((resolve, reject) => {
    const probe = http.request(
      { hostname: HOST, port: PORT, path: '/health', method: 'GET', timeout: 500 },
      (res) => {
        res.on('data', () => {});
        res.on('end', () => resolve());
      }
    );
    probe.on('error', () => {
      // Server not running; spawn it.
      const child = spawn(process.execPath, [path.join(SERVICE_PATH, 'normalize-server.js')], {
        cwd: SERVICE_PATH,
        stdio: 'ignore',
        detached: false,
      });
      serverStartedHere = true;
      child.on('error', reject);
      // Give it a moment to come up.
      setTimeout(resolve, 250);
    });
    probe.on('timeout', () => {
      probe.destroy();
      const child = spawn(process.execPath, [path.join(SERVICE_PATH, 'normalize-server.js')], {
        cwd: SERVICE_PATH,
        stdio: 'ignore',
        detached: false,
      });
      serverStartedHere = true;
      child.on('error', reject);
      setTimeout(resolve, 250);
    });
    probe.end();
  });
  return serverStartPromise;
}

/**
 * Format an agent reply for Discord delivery.
 *
 * @param {{agent_id: string, text: string, identity_registry?: object}} opts
 * @returns {Promise<{content: string, chunks: string[], username: string, avatar_url: string}>}
 */
async function formatReply(opts) {
  if (!opts || !opts.agent_id || typeof opts.text !== 'string') {
    throw new Error('formatReply: {agent_id, text} required');
  }
  await ensureServer();
  return postJson({
    agent_id: opts.agent_id,
    text: opts.text,
    identity_registry: opts.identity_registry || {},
  });
}

module.exports = {
  formatReply,
  // Exposed for test setups and one-off debugging
  _ensureServer: ensureServer,
  _serverStartedHere: () => serverStartedHere,
};
