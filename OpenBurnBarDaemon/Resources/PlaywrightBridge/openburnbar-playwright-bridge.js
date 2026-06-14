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
 *
 * SSRF policy: the target guard runs in two layers. The synchronous string
 * check (`isBlockedBrowserURL`) rejects literal loopback/link-local/private/
 * metadata IPs and non-http(s) schemes. The async check
 * (`resolvesToBlockedAddress`) defeats DNS-rebinding and named-internal-host
 * redirects by RESOLVING the hostname and blocking if any resolved address is
 * internal — closing the gap where `attacker.test` → 127.0.0.1 bypassed the
 * string-only guard. Both run at the context-wide route chokepoint, so every
 * request (incl. redirects and subresources) is re-checked. The pure policy
 * functions are exported for deterministic unit tests
 * (`scripts/test-playwright-bridge-guard.mjs`); the live bridge only runs when
 * this file is executed directly.
 */
'use strict';

const net = require('net');
const dnsPromises = require('dns').promises;

// ---------------------------------------------------------------------------
// Pure target-policy helpers (no side effects; exported for unit tests).
// ---------------------------------------------------------------------------

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

// Extracts the embedded IPv4 from an IPv4-mapped/compatible IPv6 address, in
// both the dotted form (`::ffff:127.0.0.1`) and the WHATWG-canonical hex form
// (`::ffff:7f00:1`, which `new URL()` produces). Returns null for ordinary
// IPv6 so a bare trailing hextet is NOT misread as a decimal IPv4.
function mappedIPv4FromIPv6(normalized) {
  const tail = normalized.slice(normalized.lastIndexOf(':') + 1);
  if (tail.includes('.')) {
    const bytes = ipv4Bytes(tail);
    if (bytes) return bytes;
  }
  const hex = /^::(?:ffff:)?([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(normalized);
  if (hex) {
    const hi = Number.parseInt(hex[1], 16);
    const lo = Number.parseInt(hex[2], 16);
    return [(hi >>> 8) & 0xff, hi & 0xff, (lo >>> 8) & 0xff, lo & 0xff];
  }
  return null;
}

function isBlockedIPv6(host) {
  const normalized = host.toLowerCase();
  if (normalized === '::' || normalized === '::1') return true;
  const mapped = mappedIPv4FromIPv6(normalized);
  if (mapped && isBlockedIPv4(mapped)) return true;
  const first = firstIPv6Hextet(normalized);
  if (first === null) return false;
  if ((first & 0xffc0) === 0xfe80) return true; // fe80::/10 link-local
  if ((first & 0xfe00) === 0xfc00) return true; // fc00::/7 unique-local
  return (first & 0xff00) === 0xff00;           // ff00::/8 multicast
}

function normalizeHost(rawHost) {
  return String(rawHost || '')
    .replace(/^\[/, '')
    .replace(/\]$/, '')
    .replace(/\.$/, '')
    .toLowerCase();
}

function isLiteralIP(host) {
  return Boolean(ipv4Bytes(host)) || net.isIP(host) !== 0;
}

function isBlockedLiteralHost(host) {
  if (!host) return true;
  if (host === 'localhost' || host.endsWith('.localhost')) return true;
  if (host === 'metadata' || host === 'metadata.google.internal' || host.endsWith('.metadata.google.internal')) return true;
  const ipv4 = ipv4Bytes(host);
  if (ipv4) return isBlockedIPv4(ipv4);
  if (net.isIP(host) === 6) return isBlockedIPv6(host);
  return false;
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
  return isBlockedLiteralHost(normalizeHost(parsed.hostname));
}

async function defaultResolver(host) {
  return dnsPromises.lookup(host, { all: true });
}

/**
 * SSRF / DNS-rebinding defense. Resolves a *named* host and blocks if ANY
 * resolved address is loopback/link-local/private/metadata. Literal-IP hosts
 * return `false` here because the synchronous string check already covers them.
 * Fails CLOSED on resolution error or an empty record set: an unresolvable host
 * cannot load a real page anyway, and treating it as blocked removes a bypass
 * via deliberately-flaky / split-horizon names.
 *
 * @param {string} host raw hostname (will be normalized)
 * @param {(h:string)=>Promise<Array<{address:string,family:number}|string>>} resolver injectable for tests
 */
async function resolvesToBlockedAddress(host, resolver = defaultResolver) {
  const normalized = normalizeHost(host);
  if (!normalized) return true;
  if (isLiteralIP(normalized)) return false;
  let records;
  try {
    records = await resolver(normalized);
  } catch {
    return true;
  }
  if (!Array.isArray(records) || records.length === 0) return true;
  for (const record of records) {
    const address = typeof record === 'string' ? record : (record && record.address);
    if (!address) return true;
    if (net.isIP(address) === 6) {
      if (isBlockedIPv6(String(address).toLowerCase())) return true;
    } else {
      const bytes = ipv4Bytes(address);
      if (!bytes || isBlockedIPv4(bytes)) return true;
    }
  }
  return false;
}

/**
 * Combined chokepoint gate: synchronous literal check, then resolve-and-block
 * for named http(s) hosts. Returns true when the target must be blocked.
 */
async function isBlockedBrowserTarget(rawValue, { allowData = false, resolver = defaultResolver } = {}) {
  if (isBlockedBrowserURL(rawValue, { allowData })) return true;
  let parsed;
  try {
    parsed = new URL(String(rawValue || '').trim());
  } catch {
    return true;
  }
  const protocol = parsed.protocol.toLowerCase();
  // data:/about:/blob: passed the string check and have no resolvable host.
  if (protocol !== 'http:' && protocol !== 'https:') return false;
  const host = normalizeHost(parsed.hostname);
  if (!host || isLiteralIP(host)) return false;
  return resolvesToBlockedAddress(host, resolver);
}

module.exports = {
  parseIPv4Part,
  ipv4Bytes,
  isBlockedIPv4,
  isBlockedIPv6,
  normalizeHost,
  isLiteralIP,
  isBlockedLiteralHost,
  isBlockedBrowserURL,
  resolvesToBlockedAddress,
  isBlockedBrowserTarget,
};

// ---------------------------------------------------------------------------
// Live bridge (only when executed directly — kept out of the module import
// path so unit tests never require playwright or spawn the process).
// ---------------------------------------------------------------------------

function runBridge() {
  const readline = require('readline');

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

  // Per-session host→blocked cache bounds the per-request DNS latency the async
  // guard adds; a host is resolved at most once per bridge process.
  const resolvedHostBlockCache = new Map();

  async function targetBlocked(rawValue, opts = {}) {
    if (isBlockedBrowserURL(rawValue, opts)) return true;
    let host;
    try {
      host = normalizeHost(new URL(String(rawValue || '').trim()).hostname);
    } catch {
      return true;
    }
    if (!host || isLiteralIP(host)) return false;
    if (resolvedHostBlockCache.has(host)) return resolvedHostBlockCache.get(host);
    const blocked = await resolvesToBlockedAddress(host);
    resolvedHostBlockCache.set(host, blocked);
    return blocked;
  }

  async function installNetworkGuard(ctx) {
    await ctx.route('**/*', async (route) => {
      const url = route.request().url();
      if (await targetBlocked(url, { allowData: true })) {
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
        // T-AI-04: attach the live landed URL (finalURL) so the daemon can
        // re-validate JS-driven navigation a click may have triggered
        // (anti-rebind / SSRF). A non-navigating click reports the unchanged URL.
        if (params.selector) {
          await p.click(params.selector, { timeout, force: false });
          return { kind: 'click', selector: params.selector, finalURL: p.url() };
        } else if (typeof params.positionX === 'number' && typeof params.positionY === 'number') {
          await p.mouse.click(params.positionX, params.positionY);
          return { kind: 'click', position: [params.positionX, params.positionY], finalURL: p.url() };
        } else {
          throw new Error('click requires selector or position');
        }
      }
      case 'fill': {
        await p.fill(params.selector, params.text, { timeout });
        return { kind: 'fill', selector: params.selector, charCount: (params.text || '').length, finalURL: p.url() };
      }
      case 'goto': {
        if (await targetBlocked(params.url, { allowData: true })) {
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
        // T-AI-04: a keypress (e.g. Enter in an address bar / form) can navigate.
        return { kind: 'key', combo, finalURL: p.url() };
      }
      case 'select': {
        await p.selectOption(params.selector, params.value);
        return { kind: 'select', selector: params.selector, value: params.value, finalURL: p.url() };
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
}

if (require.main === module) {
  runBridge();
}
