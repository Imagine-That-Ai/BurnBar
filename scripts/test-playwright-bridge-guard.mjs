#!/usr/bin/env node
/**
 * Deterministic unit tests for the Playwright bridge SSRF target policy.
 *
 * Unlike scripts/test-computer-use-browser-scenarios.mjs (which spawns real
 * Chromium), this imports the bridge's pure policy functions and exercises the
 * synchronous literal guard AND the async resolve-and-block guard with an
 * injected resolver — so DNS-rebinding / named-internal-host SSRF is covered
 * without needing a real rebinding domain or a browser. Closes the audit
 * residual "tests don't cover rebinding".
 *
 * Run: node scripts/test-playwright-bridge-guard.mjs
 */
'use strict';

import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const guard = require(path.join(root, 'OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js'));

let failures = 0;
function check(label, cond) {
  if (cond) {
    console.log(`ok   ${label}`);
  } else {
    failures += 1;
    console.error(`FAIL ${label}`);
  }
}
async function checkAsync(label, promise, expected) {
  try {
    const actual = await promise;
    check(`${label} (=> ${actual})`, actual === expected);
  } catch (e) {
    failures += 1;
    console.error(`FAIL ${label} threw: ${e.message}`);
  }
}

// Fake resolvers (deterministic — no real DNS).
const resolveTo = (...addresses) => async () => addresses.map((a) => ({
  address: a,
  family: a.includes(':') ? 6 : 4,
}));
const resolveStrings = (...addresses) => async () => addresses; // string-form records
const resolveThrows = async () => { throw new Error('ENOTFOUND'); };
const resolveEmpty = async () => [];

async function main() {
  // ---- Layer 1: synchronous literal guard (regression coverage) ----
  const blockedLiterals = [
    'http://127.0.0.1/', 'http://localhost/', 'http://foo.localhost/',
    'http://169.254.169.254/latest/meta-data', 'http://metadata.google.internal/',
    'http://2130706433/',            // decimal localhost
    'http://0x7f.0.0.1/',            // hex octet
    'http://allowed@127.0.0.1/',     // userinfo trick
    'http://10.0.0.5/', 'http://192.168.1.1/', 'http://172.16.0.1/',
    'http://[::1]/', 'http://[::ffff:127.0.0.1]/', 'http://[fe80::1]/',
    'ftp://example.com/', 'file:///etc/passwd', 'http://127.0.0.1.:8642/',
  ];
  for (const url of blockedLiterals) {
    check(`literal blocked: ${url}`, guard.isBlockedBrowserURL(url, { allowData: true }) === true);
  }
  const allowedLiterals = ['https://example.com/', 'https://en.wikipedia.org/', 'http://93.184.216.34/'];
  for (const url of allowedLiterals) {
    check(`literal allowed: ${url}`, guard.isBlockedBrowserURL(url, { allowData: true }) === false);
  }
  check('data: URL allowed when allowData', guard.isBlockedBrowserURL('data:text/html,hi', { allowData: true }) === false);
  check('data: URL blocked when !allowData', guard.isBlockedBrowserURL('data:text/html,hi') === true);

  // ---- Layer 2: resolve-and-block (DNS rebinding / named internal host) ----
  // The prize: a benign-looking domain that RESOLVES to the daemon gateway / metadata.
  await checkAsync('rebind → 127.0.0.1 blocked',
    guard.resolvesToBlockedAddress('attacker.test', resolveTo('127.0.0.1')), true);
  await checkAsync('rebind → 169.254.169.254 (metadata) blocked',
    guard.resolvesToBlockedAddress('metadata-proxy.test', resolveTo('169.254.169.254')), true);
  await checkAsync('rebind → 10.x private blocked',
    guard.resolvesToBlockedAddress('intranet.test', resolveTo('10.1.2.3')), true);
  await checkAsync('rebind → ::1 blocked',
    guard.resolvesToBlockedAddress('v6.test', resolveTo('::1')), true);
  await checkAsync('rebind → public 8.8.8.8 allowed',
    guard.resolvesToBlockedAddress('cdn.test', resolveTo('8.8.8.8')), false);
  await checkAsync('rebind → public v6 allowed',
    guard.resolvesToBlockedAddress('v6cdn.test', resolveTo('2001:4860:4860::8888')), false);
  await checkAsync('multi-record with ONE internal blocked (no leaky any-public-passes)',
    guard.resolvesToBlockedAddress('split.test', resolveTo('8.8.8.8', '127.0.0.1')), true);
  await checkAsync('string-form records handled (127.0.0.1)',
    guard.resolvesToBlockedAddress('strform.test', resolveStrings('127.0.0.1')), true);
  await checkAsync('resolution failure fails CLOSED',
    guard.resolvesToBlockedAddress('nxdomain.test', resolveThrows), true);
  await checkAsync('empty record set fails CLOSED',
    guard.resolvesToBlockedAddress('empty.test', resolveEmpty), true);
  await checkAsync('literal IP skips resolution (public, allowed)',
    guard.resolvesToBlockedAddress('8.8.8.8', resolveThrows), false);

  // ---- Combined chokepoint gate ----
  await checkAsync('chokepoint: named host → loopback blocked',
    guard.isBlockedBrowserTarget('http://gateway.test:8642/', { allowData: true, resolver: resolveTo('127.0.0.1') }), true);
  await checkAsync('chokepoint: literal loopback blocked (sync, resolver never consulted)',
    guard.isBlockedBrowserTarget('http://127.0.0.1:8642/', { allowData: true, resolver: resolveThrows }), true);
  await checkAsync('chokepoint: public host allowed',
    guard.isBlockedBrowserTarget('https://example.com/', { allowData: true, resolver: resolveTo('93.184.216.34') }), false);
  await checkAsync('chokepoint: data: URL allowed',
    guard.isBlockedBrowserTarget('data:text/html,hi', { allowData: true, resolver: resolveThrows }), false);

  if (failures > 0) {
    console.error(`\nplaywright bridge guard: FAILED (${failures} failing checks)`);
    process.exit(1);
  }
  console.log('\nplaywright bridge guard: OK — literal + DNS-rebinding SSRF blocked, fail-closed on resolution error');
}

main().catch((e) => {
  console.error(`playwright bridge guard: ERROR ${e.stack || e.message}`);
  process.exit(1);
});
