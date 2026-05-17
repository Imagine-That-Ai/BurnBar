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
