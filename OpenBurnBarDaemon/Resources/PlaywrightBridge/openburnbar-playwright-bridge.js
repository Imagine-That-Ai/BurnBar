#!/usr/bin/env node
/**
 * OpenBurnBar Computer Use — Playwright bridge.
 *
 * Reads newline-delimited JSON-RPC requests on stdin, dispatches each
 * request against a single chromium Browser/Context/Page, writes
 * newline-delimited JSON-RPC responses on stdout. One subprocess per
 * Computer Use session.
 *
 * Spec: plans/2026-05-16-computer-use-master-plan.md § B.3.
 *
 * Wire envelope:
 *   request:  {"id": 1, "method": "click", "params": {...}}
 *   response: {"id": 1, "ok": true,  "result": ...,  "elapsedMillis": 87}
 *   response: {"id": 1, "ok": false, "error":  "...", "elapsedMillis": 12}
 *
 * Logs go to stderr.
 */
'use strict';

const readline = require('readline');
const path = require('path');
const net = require('net');

let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  console.error('[playwright-bridge] failed to require playwright:', e.message);
  process.exit(2);
}

const argv = process.argv.slice(2);
function flag(name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : null;
}
function hasFlag(name) { return argv.indexOf(name) >= 0; }

const sessionId = flag('--session-id') || 'unknown';
const perActionTimeoutMs = parseInt(flag('--per-action-timeout-ms') || '10000', 10);
const headless = hasFlag('--headless');
const channel = flag('--channel');
const userDataDir = flag('--user-data-dir');

let browser = null;
let context = null;
let page = null;

function parseIPv4Part(raw) {
  if (!raw) return null;
  const lower = String(raw).toLowerCase();
  let radix = 10;
  let digits = lower;
  if (lower.startsWith('0x')) {
    radix = 16;
    digits = lower.slice(2);
  } else if (lower.length > 1 && lower.startsWith('0')) {
    radix = 8;
    digits = lower.slice(1);
  }
  if (!digits) return 0;
  const pattern = radix === 16 ? /^[0-9a-f]+$/ : (radix === 8 ? /^[0-7]+$/ : /^[0-9]+$/);
  if (!pattern.test(digits)) return null;
  const value = Number.parseInt(digits, radix);
  return Number.isSafeInteger(value) ? value : null;
}

function ipv4Bytes(host) {
  const parts = String(host).split('.');
  if (parts.length < 1 || parts.length > 4) return null;
  const values = parts.map(parseIPv4Part);
  if (values.some((value) => value === null)) return null;
  if (values.length === 1) {
    const value = values[0];
    if (value > 0xffffffff) return null;
    return [(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff];
  }
  if (values.length === 2) {
    if (values[0] > 0xff || values[1] > 0x00ffffff) return null;
    return [values[0], (values[1] >>> 16) & 0xff, (values[1] >>> 8) & 0xff, values[1] & 0xff];
  }
  if (values.length === 3) {
    if (values[0] > 0xff || values[1] > 0xff || values[2] > 0xffff) return null;
    return [values[0], values[1], (values[2] >>> 8) & 0xff, values[2] & 0xff];
  }
  if (values.some((value) => value > 0xff)) return null;
  return values;
}

function isBlockedIPv4(bytes) {
  if (!bytes || bytes.length !== 4) return true;
  const [first, second] = bytes;
  if (first === 0 || first === 10 || first === 127) return true;
  if (first === 100 && second >= 64 && second <= 127) return true;
  if (first === 169 && second === 254) return true;
  if (first === 172 && second >= 16 && second <= 31) return true;
  if (first === 192 && second === 168) return true;
  if (first === 198 && (second === 18 || second === 19)) return true;
  if (first >= 224) return true;
  return bytes.every((byte) => byte === 255);
}

function firstIPv6Hextet(host) {
  const match = /^([0-9a-f]{1,4})/i.exec(host);
  return match ? Number.parseInt(match[1], 16) : null;
}

function isBlockedIPv6(host) {
  const normalized = host.toLowerCase();
  if (normalized === '::' || normalized === '::1') return true;
  const embeddedIPv4 = normalized.match(/(?:^|:)(\d+|0x[0-9a-f]+|0[0-7]+(?:\.(?:\d+|0x[0-9a-f]+|0[0-7]+)){0,3})$/i);
  if (embeddedIPv4) {
    const embedded = ipv4Bytes(embeddedIPv4[1]);
    if (embedded && isBlockedIPv4(embedded)) return true;
  }
  const first = firstIPv6Hextet(normalized);
  if (first === null) return false;
  if ((first & 0xffc0) === 0xfe80) return true;
  if ((first & 0xfe00) === 0xfc00) return true;
  return (first & 0xff00) === 0xff00;
}

function isBlockedBrowserURL(rawValue, { allowData = false } = {}) {
  let parsed;
  try {
    parsed = new URL(String(rawValue || '').trim());
  } catch {
    return true;
  }
  const protocol = parsed.protocol.toLowerCase();
  if (allowData && protocol === 'data:') return false;
  if (protocol === 'about:' || protocol === 'blob:') return false;
  if (protocol !== 'http:' && protocol !== 'https:') return true;
  const host = parsed.hostname.replace(/^\[/, '').replace(/\]$/, '').replace(/\.$/, '').toLowerCase();
  if (!host) return true;
  if (host === 'localhost' || host.endsWith('.localhost')) return true;
  if (host === 'metadata' || host === 'metadata.google.internal' || host.endsWith('.metadata.google.internal')) return true;
  const ipv4 = ipv4Bytes(host);
  if (ipv4) return isBlockedIPv4(ipv4);
  if (net.isIP(host) === 6) return isBlockedIPv6(host);
  return false;
}

async function installNetworkGuard(ctx) {
  await ctx.route('**/*', async (route) => {
    const url = route.request().url();
    if (isBlockedBrowserURL(url, { allowData: true })) {
      console.error(`[playwright-bridge] blocked browser target: ${url}`);
      await route.abort('blockedbyclient');
      return;
    }
    await route.continue();
  });
}

async function ensurePage() {
  if (page) return page;
  const launchOpts = { headless };
  if (channel) launchOpts.channel = channel;
  if (userDataDir) {
    context = await chromium.launchPersistentContext(userDataDir, launchOpts);
    browser = null;
  } else {
    browser = await chromium.launch(launchOpts);
    context = await browser.newContext();
  }
  await installNetworkGuard(context);
  page = await context.newPage();
  return page;
}

async function dispatch(method, params) {
  const timeout = (params && typeof params.timeoutMs === 'number') ? params.timeoutMs : perActionTimeoutMs;
  const p = await ensurePage();
  switch (method) {
    case 'click': {
      if (params.selector) {
        await p.click(params.selector, { timeout, force: false });
        return { kind: 'click', selector: params.selector };
      } else if (typeof params.positionX === 'number' && typeof params.positionY === 'number') {
        await p.mouse.click(params.positionX, params.positionY);
        return { kind: 'click', position: [params.positionX, params.positionY] };
      } else {
        throw new Error('click requires selector or position');
      }
    }
    case 'fill': {
      await p.fill(params.selector, params.text, { timeout });
      return { kind: 'fill', selector: params.selector, charCount: (params.text || '').length };
    }
    case 'goto': {
      if (isBlockedBrowserURL(params.url, { allowData: true })) {
        throw new Error(`blocked browser target: ${params.url}`);
      }
      const resp = await p.goto(params.url, { timeout, waitUntil: 'domcontentloaded' });
      return {
        kind: 'goto',
        url: params.url,
        status: resp ? resp.status() : null,
        finalURL: p.url()
      };
    }
    case 'key': {
      const combo = (params.modifiers && params.modifiers.length)
        ? `${params.modifiers.join('+')}+${params.key}`
        : params.key;
      await p.keyboard.press(combo);
      return { kind: 'key', combo };
    }
    case 'select': {
      await p.selectOption(params.selector, params.value);
      return { kind: 'select', selector: params.selector, value: params.value };
    }
    case 'screenshot': {
      const buf = await p.screenshot({ fullPage: !!params.fullPage });
      return { kind: 'screenshot', sizeBytes: buf.length, base64: buf.toString('base64') };
    }
    case 'extract': {
      const text = params.selector
        ? await p.textContent(params.selector)
        : await p.content();
      return { kind: 'extract', selector: params.selector, text };
    }
    case 'current_url': return { kind: 'current_url', url: p.url() };
    case 'current_title': return { kind: 'current_title', title: await p.title() };
    case 'shutdown': {
      try { if (browser) await browser.close(); } catch (_) {}
      try { if (context) await context.close(); } catch (_) {}
      return { kind: 'shutdown' };
    }
    default:
      throw new Error(`unknown method ${method}`);
  }
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on('line', async (line) => {
  if (!line) return;
  let req;
  try { req = JSON.parse(line); } catch (e) {
    console.error('[playwright-bridge] malformed request:', e.message);
    return;
  }
  const started = Date.now();
  let response;
  try {
    const result = await dispatch(req.method, req.params || {});
    response = {
      id: req.id,
      ok: true,
      result,
      elapsedMillis: Date.now() - started
    };
  } catch (e) {
    response = {
      id: req.id,
      ok: false,
      error: String(e && e.message ? e.message : e),
      elapsedMillis: Date.now() - started
    };
  }
  const shouldExit = req.method === 'shutdown' && response.ok;
  process.stdout.write(JSON.stringify(response) + '\n', () => {
    if (shouldExit) process.exit(0);
  });
});

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));

console.error(`[playwright-bridge] session=${sessionId} headless=${headless} channel=${channel || 'default'} ready`);
