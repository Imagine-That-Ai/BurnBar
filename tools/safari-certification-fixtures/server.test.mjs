import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';

import {
  PRIMARY_ROUTE_DEFINITIONS,
  SECONDARY_ROUTE_DEFINITIONS,
  assertLoopbackBindHost,
  parseInteger,
  startFixtureServers
} from './server.mjs';
import { verify } from './verify.mjs';

async function withServers(run) {
  const servers = await startFixtureServers({ port: 0, crossOriginPort: 0 });
  try {
    await run(servers);
  } finally {
    await servers.close();
  }
}

function requestWithHost(url, hostHeader) {
  const parsed = new URL(url);
  return new Promise((resolve, reject) => {
    const request = http.request(
      {
        hostname: parsed.hostname,
        port: parsed.port,
        path: parsed.pathname,
        method: 'GET',
        headers: { Host: hostHeader }
      },
      (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => {
          resolve({
            status: response.statusCode,
            headers: response.headers,
            body: Buffer.concat(chunks).toString('utf8')
          });
        });
      }
    );
    request.on('error', reject);
    request.end();
  });
}

test('manifest and every deterministic asset hash verify', async () => {
  const result = await verify();
  assert.equal(result.fixtureCount, 10);
  assert.ok(result.assetCount >= 29);
  assert.match(result.assetRootSha256, /^[a-f0-9]{64}$/u);
});

test('all primary and secondary fixture routes are read-only and no-store', async () => {
  await withServers(async ({ primaryOrigin, secondaryOrigin }) => {
    for (const route of Object.keys(PRIMARY_ROUTE_DEFINITIONS)) {
      const response = await fetch(`${primaryOrigin}${route}`);
      assert.equal(response.status, 200, route);
      assert.match(response.headers.get('content-type') ?? '', /(?:text\/html|text\/css|javascript|image\/svg\+xml)/u);
      assert.equal(response.headers.get('cache-control'), 'no-store, max-age=0');
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      assert.ok(response.headers.get('content-security-policy'));
      assert.ok((await response.arrayBuffer()).byteLength > 0);
    }

    for (const route of Object.keys(SECONDARY_ROUTE_DEFINITIONS)) {
      const response = await fetch(`${secondaryOrigin}${route}`);
      assert.equal(response.status, 200, route);
      assert.match(response.headers.get('content-type') ?? '', /text\/html/u);
      assert.equal(response.headers.get('cache-control'), 'no-store, max-age=0');
    }
  });
});

test('live manifest binds the static asset manifest to both runtime origins', async () => {
  await withServers(async ({ primaryOrigin, secondaryOrigin }) => {
    const response = await fetch(`${primaryOrigin}/manifest.json`);
    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type') ?? '', /application\/json/u);
    const manifest = await response.json();
    assert.equal(manifest.fixtures.length, 10);
    assert.equal(manifest.runtime.primaryOrigin, primaryOrigin);
    assert.equal(manifest.runtime.secondaryOrigin, secondaryOrigin);
    assert.match(manifest.assetRootSha256, /^[a-f0-9]{64}$/u);
    assert.ok(Object.keys(manifest.assets).includes('vendor/react.production.min.js'));
    assert.ok(Object.keys(manifest.assets).includes('vendor/react-dom.production.min.js'));
  });
});

test('frame fixture uses the dedicated secondary loopback origin and exact frame CSP', async () => {
  await withServers(async ({ primaryOrigin, secondaryOrigin }) => {
    const response = await fetch(`${primaryOrigin}/frames`);
    const body = await response.text();
    assert.match(body, new RegExp(`${secondaryOrigin.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}/frame/cross`, 'u'));
    assert.match(response.headers.get('content-security-policy') ?? '', new RegExp(`frame-src 'self' ${secondaryOrigin}`, 'u'));

    const same = await fetch(`${primaryOrigin}/frame/same`);
    assert.match(same.headers.get('content-security-policy') ?? '', new RegExp(`frame-ancestors ${primaryOrigin}`, 'u'));

    const cross = await fetch(`${secondaryOrigin}/frame/cross`);
    assert.match(cross.headers.get('content-security-policy') ?? '', new RegExp(`frame-ancestors ${primaryOrigin}`, 'u'));

    const crossStyles = await fetch(`${secondaryOrigin}/assets/styles.css`);
    assert.equal(crossStyles.status, 200);
    assert.match(crossStyles.headers.get('content-type') ?? '', /text\/css/u);
    assert.equal(crossStyles.headers.get('cache-control'), 'no-store, max-age=0');
    assert.ok(crossStyles.headers.get('content-security-policy'));
    assert.ok((await crossStyles.arrayBuffer()).byteLength > 0);
  });
});

test('loopback bind hosts normalize IPv6 for sockets while preserving strict admission', () => {
  assert.equal(assertLoopbackBindHost('127.0.0.1'), '127.0.0.1');
  assert.equal(assertLoopbackBindHost('localhost'), 'localhost');
  assert.equal(assertLoopbackBindHost('::1'), '::1');
  assert.equal(assertLoopbackBindHost('[::1]'), '::1');
  assert.throws(() => assertLoopbackBindHost('0.0.0.0'), /Refusing non-loopback bind host/u);
  assert.throws(() => assertLoopbackBindHost('192.168.1.10'), /Refusing non-loopback bind host/u);
});

test('port parser accepts only complete unsigned decimal integers in range', () => {
  assert.equal(parseInteger(undefined, 41_771, 'Port'), 41_771);
  assert.equal(parseInteger(0, 41_771, 'Port'), 0);
  assert.equal(parseInteger('0', 41_771, 'Port'), 0);
  assert.equal(parseInteger('65535', 41_771, 'Port'), 65_535);
  for (const value of ['', ' ', '-1', '+1', '01', '1.5', '1x', '1e3', '65536']) {
    assert.throws(
      () => parseInteger(value, 41_771, 'Port'),
      /Port must be an integer from 0 through 65535/u,
      value
    );
  }
});

test('strict CSP has no unsafe inline allowance and protected submissions fail closed', async () => {
  await withServers(async ({ primaryOrigin }) => {
    const strict = await fetch(`${primaryOrigin}/strict-csp`);
    const csp = strict.headers.get('content-security-policy') ?? '';
    assert.match(csp, /script-src 'self'/u);
    assert.doesNotMatch(csp, /unsafe-inline/u);
    assert.match(csp, /form-action 'none'/u);
    assert.match(csp, /frame-ancestors 'none'/u);

    const protectedPost = await fetch(`${primaryOrigin}/protected/banking/submit`, {
      method: 'POST',
      body: new URLSearchParams({ password: 'fixture-only' }),
      redirect: 'manual'
    });
    assert.equal(protectedPost.status, 405);
    assert.deepEqual(await protectedPost.json(), { ok: false, error: 'fixture_is_read_only' });
  });
});

test('non-loopback Host headers and bind addresses are refused', async () => {
  await withServers(async ({ primaryOrigin }) => {
    const response = await requestWithHost(`${primaryOrigin}/healthz`, 'attacker.example');
    assert.equal(response.status, 421);
    assert.deepEqual(JSON.parse(response.body), { ok: false, error: 'loopback_host_required' });
  });

  await assert.rejects(
    () => startFixtureServers({ host: '0.0.0.0', port: 0, crossOriginPort: 0 }),
    /Refusing non-loopback bind host/u
  );
});

test('unknown routes return typed JSON errors and health routes disclose no mutable state', async () => {
  await withServers(async ({ primaryOrigin, secondaryOrigin }) => {
    const missing = await fetch(`${primaryOrigin}/not-a-fixture`);
    assert.equal(missing.status, 404);
    assert.deepEqual(await missing.json(), { ok: false, error: 'fixture_route_not_found' });

    const primaryHealth = await (await fetch(`${primaryOrigin}/healthz`)).json();
    const secondaryHealth = await (await fetch(`${secondaryOrigin}/healthz`)).json();
    assert.deepEqual(primaryHealth, {
      ok: true,
      fixtureServer: 'openburnbar-safari-certification',
      originRole: 'primary'
    });
    assert.deepEqual(secondaryHealth, {
      ok: true,
      fixtureServer: 'openburnbar-safari-certification',
      originRole: 'secondary'
    });
  });
});
