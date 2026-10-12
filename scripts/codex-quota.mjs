#!/usr/bin/env node
// Queries the codex rate limits and prints one line: "<codex|claude>\t<reason>".
// Always exits 0; any query failure falls back to "codex".
//
// Env:
//   CODEX_QUOTA_CODEX_BIN    codex executable (default: "codex" from PATH)
//   CODEX_QUOTA_TIMEOUT_MS   overall timeout in ms (default 15000); tests only
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

const WEEK_MINS = 10080;
const WEEK_SECS = WEEK_MINS * 60;
const USAGE_CAP = 95;
const PACE_MARGIN = 5;
const TIMEOUT_MS = Number(process.env.CODEX_QUOTA_TIMEOUT_MS) || 15000;
const BIN = process.env.CODEX_QUOTA_CODEX_BIN || 'codex';

const isObject = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
const isFiniteNum = (v) => typeof v === 'number' && Number.isFinite(v);

// usedPercent is reported exactly as the server gave it; rounding could hide
// why the 95% cap did or did not trigger.
const fmt = (n) => String(n);

function windowLabel(mins) {
  if (mins === WEEK_MINS) return 'weekly';
  if (mins === 300) return '5h-window';
  if (Number.isInteger(mins) && mins > 0) return `${mins}m-window`;
  return 'unknown-window';
}

function decide(rl) {
  if (typeof rl.rateLimitReachedType === 'string' && rl.rateLimitReachedType !== '') {
    return ['claude', `auto-downgraded: codex rate limit reached [${rl.rateLimitReachedType}]`];
  }

  const windows = [rl.primary, rl.secondary].filter(isObject);

  for (const w of windows) {
    if (isFiniteNum(w.usedPercent) && w.usedPercent >= USAGE_CAP) {
      return ['claude', `auto-downgraded: codex ${windowLabel(w.windowDurationMins)} usage ${fmt(w.usedPercent)}% reached ${USAGE_CAP}% cap`];
    }
  }

  const weekly = windows.find((w) => w.windowDurationMins === WEEK_MINS);
  if (!weekly) {
    return ['codex', 'codex quota unavailable: no weekly (10080m) window in response'];
  }
  if (!isFiniteNum(weekly.usedPercent) || !isFiniteNum(weekly.resetsAt)) {
    return ['codex', 'codex quota unavailable: weekly window has invalid usedPercent/resetsAt'];
  }
  const now = Date.now() / 1000;
  const elapsed = Math.min(1, Math.max(0, (now - (weekly.resetsAt - WEEK_SECS)) / WEEK_SECS));
  // Compare against the same rounded limit that is shown in the reason.
  const limit = Math.round(elapsed * 100 + PACE_MARGIN);
  if (weekly.usedPercent > limit) {
    return ['claude', `auto-downgraded: codex weekly usage ${fmt(weekly.usedPercent)}% exceeds even-pace limit ${limit}%`];
  }
  return ['codex', 'codex quota ok'];
}

let child = null;
let done = false;

function finish(backend, reason) {
  if (done) return;
  done = true;
  if (child && child.pid) {
    try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already gone */ }
  }
  // Server-provided text may hold control whitespace; keep the output one line.
  const oneLine = reason.replace(/[\s\x00-\x1f\x7f]+/g, ' ').trim();
  process.stdout.write(`${backend}\t${oneLine}\n`, () => process.exit(0));
  // Do not wait on pipes or child exit: a grandchild may keep them open.
  setTimeout(() => process.exit(0), 500).unref();
}

const fail = (why) => finish('codex', `codex quota unavailable: ${why}`);

function handleResponse(msg) {
  if (msg.error !== undefined) {
    const m = isObject(msg.error) && typeof msg.error.message === 'string' ? msg.error.message : 'error response';
    return fail(m);
  }
  if (!isObject(msg.result)) return fail('result is not an object');
  if (!isObject(msg.result.rateLimits)) return fail('rateLimits is not an object');
  const [backend, reason] = decide(msg.result.rateLimits);
  return finish(backend, reason);
}

setTimeout(() => fail(`timed out after ${TIMEOUT_MS}ms`), TIMEOUT_MS);

try {
  child = spawn(BIN, ['app-server'], { detached: true, stdio: ['pipe', 'pipe', 'ignore'] });
} catch (e) {
  fail(`cannot start codex (${e.code || e.message})`);
}

if (child) {
  child.on('error', (e) => fail(e.code === 'ENOENT' ? 'codex executable not found' : `cannot start codex (${e.code || e.message})`));
  child.on('exit', () => fail('codex app-server exited before responding'));
  child.stdin.on('error', () => {});
  child.stdout.on('error', () => {});

  createInterface({ input: child.stdout }).on('line', (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (isObject(msg) && msg.id === 2 && ('result' in msg || 'error' in msg)) handleResponse(msg);
  });

  const send = (o) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...o })}\n`);
  send({ id: 1, method: 'initialize', params: { clientInfo: { name: 'superpowers-codex-quota', version: '1.0.0' } } });
  send({ method: 'initialized' });
  send({ id: 2, method: 'account/rateLimits/read' });
}
