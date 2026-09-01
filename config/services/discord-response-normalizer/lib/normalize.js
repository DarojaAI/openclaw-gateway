'use strict';

/**
 * Discord response normalizer — pure functions, no I/O.
 *
 * Single source of truth for "what Discord sees". Applied at the gateway's
 * outbound-to-Discord boundary so every model alias and every agent emits
 * the same shape.
 *
 * Pipeline:
 *   1. Canonicalize markdown (line endings, list markers, fence noise).
 *   2. Escape Discord-significant characters outside fenced code blocks.
 *   3. Emit a deterministic identity block (Username, Avatar) per agent.
 *   4. Chunk to <=2000 chars respecting code-fence boundaries.
 *
 * No upstream dependencies. Runs identically in Node and (lightly adapted)
 * in a BATS test runner.
 */

const DISCORD_MAX = 2000;       // Hard ceiling per message chunk
const SOFT_LIMIT = 1900;        // Leave headroom for trailing newline + fences
const FENCE = '```';

const ESCAPE_RE = /([\\*_`~|>])/g;
const LIST_PREFIX_RE = /^(\s*)(\d+)\s*[\.\)\-]\s+/gm;
const DEEP_HEADING_RE = /^(#{4,6})\s+/gm;
const BLANK_RUN_RE = /\n{3,}/g;
const CRLF_RE = /\r\n?/g;
const TRAILING_WS_RE = /[ \t]+$/gm;

// ---------------------------------------------------------------------------
// Stage 1: canonicalize markdown
// ---------------------------------------------------------------------------

function canonicalize(text) {
  if (typeof text !== 'string') {
    throw new TypeError('canonicalize: expected string, got ' + typeof text);
  }
  let s = text;
  s = s.replace(CRLF_RE, '\n');
  s = s.replace(TRAILING_WS_RE, '');
  s = s.replace(DEEP_HEADING_RE, '## ');
  s = s.replace(LIST_PREFIX_RE, '$1$2. ');
  s = s.replace(BLANK_RUN_RE, '\n\n');
  s = s.replace(/^\n+/, '').replace(/\n+$/, '') + '\n';
  return s;
}

// ---------------------------------------------------------------------------
// Stage 2: escape Discord-significant characters outside code fences
// ---------------------------------------------------------------------------

function escapeOutsideFences(text) {
  let out = '';
  let i = 0;
  let inFence = false;
  const n = text.length;

  while (i < n) {
    const lineStart = i;
    let j = i;
    while (j < n && (text[j] === ' ' || text[j] === '\t')) j++;
    let runStart = j;
    while (j < n && text[j] === '`') j++;
    const backtickRun = j - runStart;

    // A fence line: optional leading whitespace, 3+ backticks, optional
    // info string, then end-of-line. The end-of-line check tolerates an
    // info string by walking past it before checking for the newline.
    if (backtickRun >= 3) {
      while (j < n && text[j] !== '\n') j++;
      inFence = !inFence;
      if (j < n) j++;
      out += text.slice(lineStart, j);
      i = j;
      continue;
    }

    const ch = text[i];
    if (!inFence && ESCAPE_RE.test(ch)) {
      out += '\\' + ch;
      ESCAPE_RE.lastIndex = 0;
    } else {
      out += ch;
    }
    i++;
  }

  return out;
}

// ---------------------------------------------------------------------------
// Stage 3: deterministic identity block
// ---------------------------------------------------------------------------

function stableIdentity(agentId, registry) {
  const reg = (registry && registry[agentId]) || {};
  const fallback = {
    username: 'openclaw-' + agentId.replace(/_/g, '-'),
    avatar_url: 'https://api.dicebear.com/9.x/identicon/svg?seed=' + encodeURIComponent(agentId),
  };
  return {
    username: reg.username || fallback.username,
    avatar_url: reg.avatar_url || fallback.avatar_url,
  };
}

// ---------------------------------------------------------------------------
// Stage 4: chunk to <=2000 chars respecting fence boundaries
// ---------------------------------------------------------------------------
//
// Two-pass design:
//
//   Pass A — line-level planning. Walk lines; for each fence, decide whether
//            the fence fits in its own chunk (small) or must be split across
//            chunks (large).
//
//   Pass B — emit chunks. For each planned unit, emit one chunk per DISCORD_MAX
//            slice, hard-splitting oversized lines at byte boundaries.
//
// Why this is simpler than tracking state across iterations:
//   - We always know the *type* of the next chunk before we emit it.
//   - Fence bodies that overflow are pre-marked; we don't have to detect
//     overflow mid-iteration and rewind.
//   - Each emitted chunk is independently valid: opener+body, body-only, or
//     body+closer. Discord renders consecutive same-bot messages as one
//     continued code block, so a fence split across multiple messages still
//     reads as one block.

function chunk(text) {
  const lines = text.split('\n');
  const chunks = [];

  // Pass A: classify each line.
  // units is an array of:
  //   { kind: 'prose', lines: [...] }        — out-of-fence lines
  //   { kind: 'fence-open', opener: '...'}   — fence opener line
  //   { kind: 'fence-body', lines: [...] }   — in-fence lines (no opener/closer)
  //   { kind: 'fence-close', closer: '...'}  — fence closer line
  const units = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.replace(/^[ \t]+/, '');
    const fenceMatch = trimmed.match(/^(`{3,})(.*)$/);
    if (fenceMatch) {
      const markerLen = fenceMatch[1].length;
      const opener = line;
      const closer = '`'.repeat(markerLen);
      // Collect body lines until we see the matching closer.
      const body = [];
      let j = i + 1;
      let foundClose = false;
      while (j < lines.length) {
        const l = lines[j];
        const t = l.replace(/^[ \t]+/, '');
        const m = t.match(/^(`{3,})/);
        if (m && m[1].length === markerLen) {
          foundClose = true;
          break;
        }
        body.push(l);
        j++;
      }
      units.push({ kind: 'fence-open', opener });
      if (body.length > 0) {
        units.push({ kind: 'fence-body', lines: body });
      }
      if (foundClose) {
        units.push({ kind: 'fence-close', closer });
      }
      i = j + (foundClose ? 1 : 0);
    } else {
      // Out-of-fence line. Accumulate into the current prose unit, or start one.
      const last = units[units.length - 1];
      if (last && last.kind === 'prose') {
        last.lines.push(line);
      } else {
        units.push({ kind: 'prose', lines: [line] });
      }
      i++;
    }
  }

  // Pass B: emit chunks.
  for (const unit of units) {
    if (unit.kind === 'fence-open') {
      chunks.push(unit.opener);
    } else if (unit.kind === 'fence-close') {
      chunks.push(unit.closer);
    } else if (unit.kind === 'prose') {
      emitLines(unit.lines, chunks);
    } else if (unit.kind === 'fence-body') {
      emitLines(unit.lines, chunks);
    }
  }

  return chunks;
}

// Emit a sequence of lines as one or more chunks, each <= DISCORD_MAX.
// Hard-splits any single line that exceeds DISCORD_MAX at byte boundaries.
// Respects SOFT_LIMIT: when a non-fence prose line would push the buffer over
// SOFT_LIMIT, flush first.
function emitLines(lines, chunks) {
  let buf = '';
  const flush = () => {
    if (buf.length > 0) {
      chunks.push(buf);
      buf = '';
    }
  };
  for (const line of lines) {
    if (line.length > DISCORD_MAX) {
      flush();
      let remaining = line;
      while (remaining.length > DISCORD_MAX) {
        chunks.push(remaining.slice(0, DISCORD_MAX));
        remaining = remaining.slice(DISCORD_MAX);
      }
      buf = remaining;
      continue;
    }
    const candidate = buf.length === 0 ? line : buf + '\n' + line;
    if (candidate.length > SOFT_LIMIT && buf.length > 0) {
      flush();
      buf = line;
    } else if (candidate.length > DISCORD_MAX) {
      flush();
      buf = line;
    } else {
      buf = candidate;
    }
  }
  flush();
}

// ---------------------------------------------------------------------------
// Top-level normalize()
// ---------------------------------------------------------------------------

function normalize(text, options) {
  if (!options || !options.agent_id) {
    throw new Error('normalize: options.agent_id is required');
  }
  const stage1 = canonicalize(text);
  const stage2 = escapeOutsideFences(stage1);
  const chunks = chunk(stage2);
  const identity = stableIdentity(options.agent_id, options.identity_registry);
  return {
    content: chunks.join('\n'),
    chunks,
    username: identity.username,
    avatar_url: identity.avatar_url,
  };
}

module.exports = {
  normalize,
  canonicalize,
  escapeOutsideFences,
  chunk,
  stableIdentity,
  DISCORD_MAX,
  SOFT_LIMIT,
};
