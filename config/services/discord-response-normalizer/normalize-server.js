#!/usr/bin/env node
'use strict';

/**
 * Discord Response Normalizer — HTTP server.
 *
 * Listens on PORT (default 8767). Two endpoints:
 *   GET  /health         — liveness probe
 *   POST /normalize      — accept {agent_id, text, identity_registry?}; return
 *                          the normalized Discord-bound payload.
 *
 * The server is intentionally tiny. All real work lives in lib/normalize.js
 * so the same logic can be invoked from tests, CLI, and the gateway's
 * outbound-to-Discord boundary without HTTP overhead in the hot path.
 */

const express = require('express');
const path = require('path');
const { normalize } = require('./lib/normalize');

const PORT = parseInt(process.env.NORMALIZER_PORT || '8767', 10);
const HOST = process.env.NORMALIZER_HOST || 'localhost';
const CACHE_DIR = process.env.NORMALIZER_CACHE_DIR || path.join(__dirname, 'cache');

const app = express();
app.use(express.json({ limit: '5mb' }));

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'discord-response-normalizer', version: '0.1.0' });
});

app.post('/normalize', (req, res) => {
  const { agent_id, text, identity_registry } = req.body || {};
  if (!agent_id || typeof agent_id !== 'string') {
    return res.status(400).json({ error: 'agent_id is required' });
  }
  if (typeof text !== 'string') {
    return res.status(400).json({ error: 'text is required' });
  }
  try {
    const result = normalize(text, {
      agent_id,
      identity_registry: identity_registry || {},
    });
    res.json(result);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Last-resort error handler. Keep last.
app.use((err, _req, res, _next) => {
  res.status(500).json({ error: err && err.message ? err.message : 'unknown error' });
});

app.listen(PORT, HOST, () => {
  // eslint-disable-next-line no-console
  console.log(`discord-response-normalizer listening on http://${HOST}:${PORT}`);
  // eslint-disable-next-line no-console
  console.log(`cache dir: ${CACHE_DIR}`);
});
