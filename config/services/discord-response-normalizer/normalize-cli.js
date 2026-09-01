#!/usr/bin/env node
'use strict';

/**
 * Discord Response Normalizer — CLI.
 *
 * Reads raw text from stdin (or --file), prints JSON to stdout.
 * Used by the gateway's outbound path, by BATS tests, and by ad-hoc
 * debugging from a shell.
 *
 * Usage:
 *   echo "raw reply" | node normalize-cli.js --agent linux_desktop_seed
 *   node normalize-cli.js --agent linux_desktop_seed --file /tmp/reply.txt
 *   node normalize-cli.js --agent linux_desktop_seed --pretty
 *
 * Zero external dependencies. Flag parsing is a tiny inline loop so the
 * CLI works on a fresh VM before `npm install` has been run.
 */

const fs = require('fs');
const { normalize } = require('./lib/normalize');

function parseArgs(argv) {
  const opts = { _: [], pretty: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--help' || a === '-h') {
      opts.help = true;
    } else if (a === '--pretty' || a === '-p') {
      opts.pretty = true;
    } else if (a === '--agent' || a === '-a') {
      opts.agent = argv[++i];
    } else if (a.startsWith('--agent=')) {
      opts.agent = a.slice('--agent='.length);
    } else if (a === '--file' || a === '-f') {
      opts.file = argv[++i];
    } else if (a.startsWith('--file=')) {
      opts.file = a.slice('--file='.length);
    } else {
      opts._.push(a);
    }
  }
  return opts;
}

const argv = parseArgs(process.argv.slice(2));

if (argv.help) {
  process.stdout.write(
    'Usage: node normalize-cli.js --agent <id> [--file <path>] [--pretty]\n' +
    'Reads from --file if given, otherwise stdin.\n'
  );
  process.exit(0);
}

if (!argv.agent) {
  process.stderr.write('ERROR: --agent is required\n');
  process.exit(2);
}

const finish = (text) => {
  const result = normalize(text, { agent_id: argv.agent });
  process.stdout.write(argv.pretty ? JSON.stringify(result, null, 2) : JSON.stringify(result));
  process.stdout.write('\n');
};

if (argv.file) {
  finish(fs.readFileSync(argv.file, 'utf8'));
  process.exit(0);
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { buf += chunk; });
process.stdin.on('end', () => finish(buf));
process.stdin.on('error', (err) => {
  process.stderr.write('ERROR: stdin: ' + err.message + '\n');
  process.exit(1);
});
