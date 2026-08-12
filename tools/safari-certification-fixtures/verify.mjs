#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import {
  DEFAULT_CROSS_ORIGIN_PORT,
  DEFAULT_HOST,
  DEFAULT_PORT,
  PRIMARY_ROUTE_DEFINITIONS,
  SECONDARY_ROUTE_DEFINITIONS
} from './server.mjs';

const TOOL_ROOT = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_ROOT = path.join(TOOL_ROOT, 'fixtures');
const MANIFEST_PATH = path.join(TOOL_ROOT, 'manifest.json');

const REQUIRED_FIXTURE_IDS = Object.freeze([
  'mixed-semantic-vision',
  'react-controlled-input-select',
  'open-shadow-root',
  'closed-shadow-page-world-bridge',
  'strict-csp',
  'infinite-scroll',
  'zoom-offset',
  'same-and-cross-origin-frames',
  'protected-banking-payment-credential',
  'run-owned-tab-navigation'
]);

const REQUIRED_ROUTES = Object.freeze([
  '/',
  '/mixed',
  '/react-controls',
  '/shadow',
  '/strict-csp',
  '/infinite-scroll',
  '/zoom-offset',
  '/frames',
  '/frame/same',
  '/protected/banking',
  '/owned-tabs/start',
  '/owned-tabs/child',
  '/owned-tabs/finish'
]);

const TRUSTED_VENDOR_RUNTIME_SHA256 = Object.freeze({
  'vendor/react.production.min.js': 'd949f1c3687aedadcedac85261865f29b17cd273997e7f6b2bfc53b2f9d4c4dd',
  'vendor/react-dom.production.min.js': '35f4f974f4b2bcd44da73963347f8952e341f83909e4498227d4e26b98f66f0d'
});

const ALLOWED_NON_REQUEST_URL_LITERALS = Object.freeze({
  'mixed-chart.svg': new Set(['http://www.w3.org/2000/svg']),
  'mixed-illustration.svg': new Set(['http://www.w3.org/2000/svg']),
  'vendor/react-dom.production.min.js': new Set([
    'http://www.w3.org/2000/svg',
    'http://www.w3.org/1998/Math/MathML',
    'http://www.w3.org/1999/xhtml',
    'http://www.w3.org/1999/xlink',
    'http://www.w3.org/XML/1998/namespace',
    'https://reactjs.org/docs/error-decoder.html?invariant='
  ])
});

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

async function listFiles(root, prefix = '') {
  const entries = await readdir(path.join(root, prefix), { withFileTypes: true });
  const files = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    const relative = path.posix.join(prefix.split(path.sep).join(path.posix.sep), entry.name);
    if (entry.isDirectory()) {
      files.push(...(await listFiles(root, relative)));
    } else if (entry.isFile()) {
      files.push(relative);
    } else {
      throw new Error(`Fixture tree contains a non-regular entry: ${relative}`);
    }
  }
  return files;
}

async function computeAssetManifest() {
  const files = await listFiles(FIXTURE_ROOT);
  const assets = {};
  const rootHasher = createHash('sha256');
  for (const relative of files) {
    const bytes = await readFile(path.join(FIXTURE_ROOT, relative));
    const digest = sha256(bytes);
    assets[relative] = digest;
    rootHasher.update(`${digest}  ${relative}\n`);
  }
  return {
    assets,
    assetRootSha256: rootHasher.digest('hex')
  };
}

function assertion(condition, message, findings) {
  if (!condition) {
    findings.push(message);
  }
}

function verifyManifestShape(manifest, findings) {
  assertion(manifest.schemaVersion === 1, 'manifest schemaVersion must be 1', findings);
  assertion(manifest.id === 'openburnbar-safari-certification-fixtures', 'manifest id is unexpected', findings);
  assertion(manifest.safety?.loopbackOnly === true, 'manifest must declare loopbackOnly=true', findings);
  assertion(
    manifest.safety?.externalNetworkRequests === false,
    'manifest must declare externalNetworkRequests=false',
    findings
  );
  assertion(manifest.safety?.realCredentials === false, 'manifest must declare realCredentials=false', findings);
  assertion(
    manifest.safety?.productionSideEffects === false,
    'manifest must declare productionSideEffects=false',
    findings
  );
  assertion(
    manifest.safety?.browserComparisonIsSafariProof === false,
    'manifest must reject browser comparison as Safari proof',
    findings
  );
  assertion(manifest.server?.defaultHost === DEFAULT_HOST, 'manifest defaultHost drifted from server', findings);
  assertion(manifest.server?.defaultPort === DEFAULT_PORT, 'manifest defaultPort drifted from server', findings);
  assertion(
    manifest.server?.defaultCrossOriginPort === DEFAULT_CROSS_ORIGIN_PORT,
    'manifest defaultCrossOriginPort drifted from server',
    findings
  );

  const fixtureIDs = Array.isArray(manifest.fixtures) ? manifest.fixtures.map((fixture) => fixture.id) : [];
  assertion(
    fixtureIDs.length === REQUIRED_FIXTURE_IDS.length,
    `manifest must contain exactly ${REQUIRED_FIXTURE_IDS.length} fixture classes`,
    findings
  );
  for (const id of REQUIRED_FIXTURE_IDS) {
    assertion(fixtureIDs.includes(id), `manifest is missing fixture id ${id}`, findings);
  }
  assertion(new Set(fixtureIDs).size === fixtureIDs.length, 'manifest contains duplicate fixture ids', findings);

  const primaryRoutes = new Set(Object.keys(PRIMARY_ROUTE_DEFINITIONS));
  for (const route of REQUIRED_ROUTES) {
    assertion(primaryRoutes.has(route), `primary server is missing required route ${route}`, findings);
  }
  assertion(
    Object.hasOwn(SECONDARY_ROUTE_DEFINITIONS, '/frame/cross'),
    'secondary server is missing /frame/cross',
    findings
  );
  for (const fixture of manifest.fixtures ?? []) {
    assertion(
      typeof fixture.route === 'string' && primaryRoutes.has(fixture.route),
      `manifest fixture ${fixture.id ?? '<unknown>'} references an unserved primary route`,
      findings
    );
    assertion(
      Array.isArray(fixture.markers) && fixture.markers.length > 0,
      `manifest fixture ${fixture.id ?? '<unknown>'} must declare stable markers`,
      findings
    );
  }
}

function isStaticallyLocalDestination(expression) {
  const value = expression.trim();
  const match = /^(["'])(.*)\1$/su.exec(value);
  if (!match) {
    return false;
  }
  const destination = match[2];
  return (
    /^\/(?!\/)[^"'\\\r\n]*$/u.test(destination) ||
    /^\{\{(?:PRIMARY|SECONDARY)_ORIGIN\}\}\/[^"'\\\r\n]*$/u.test(destination)
  );
}

function verifyDestinationSinks(relative, source, findings) {
  const sinkPatterns = [
    {
      kind: 'window.open',
      pattern: /\b(?:window\.)?open\s*\(\s*([^,\n;)]+)/giu
    },
    {
      kind: 'location assignment',
      pattern: /\b(?:window\.|document\.)?location(?:\.href)?\s*=\s*([^;\n]+)/giu
    },
    {
      kind: 'location navigation',
      pattern: /\b(?:window\.|document\.)?location\.(?:assign|replace)\s*\(\s*([^)\n]+)/giu
    },
    {
      kind: 'resource/action assignment',
      pattern: /\.(?:src|href|action|formAction)\s*=\s*([^;\n]+)/gu
    },
    {
      kind: 'resource/action setAttribute',
      pattern:
        /\.setAttribute\s*\(\s*["'](?:src|href|action|formaction)["']\s*,\s*([^)\n]+)/giu
    }
  ];

  for (const { kind, pattern } of sinkPatterns) {
    for (const match of source.matchAll(pattern)) {
      assertion(
        isStaticallyLocalDestination(match[1]),
        `${relative} contains a ${kind} destination that is not statically local`,
        findings
      );
    }
  }
}

function verifySourceSafety(relative, source, findings) {
  const trustedVendorDigest = TRUSTED_VENDOR_RUNTIME_SHA256[relative];
  const isExactTrustedVendor =
    trustedVendorDigest !== undefined && sha256(Buffer.from(source)) === trustedVendorDigest;
  if (trustedVendorDigest !== undefined) {
    assertion(
      isExactTrustedVendor,
      `${relative} does not match the pinned upstream runtime SHA-256`,
      findings
    );
  }

  const externalURLLiterals =
    source.match(
      /https?:\/\/[^\s"'()<>{}]+|\/\/(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/:?#][^\s"'()<>{}]*)?/giu
    ) ?? [];
  const allowedURLLiterals = ALLOWED_NON_REQUEST_URL_LITERALS[relative] ?? new Set();
  assertion(
    externalURLLiterals.every((value) => allowedURLLiterals.has(value)),
    `${relative} contains an external URL literal`,
    findings
  );
  const externalAttribute = /\b(?:src|href|action|formaction)\s*=\s*["'](?:https?:)?\/\//iu;
  assertion(!externalAttribute.test(source), `${relative} contains an external resource/action URL`, findings);
  const externalCSS = /(?:@import\s+(?:url\(\s*)?|url\(\s*)["']?(?:https?:)?\/\//iu;
  assertion(!externalCSS.test(source), `${relative} contains an external CSS resource URL`, findings);
  const metaRefresh =
    /<meta\b[^>]*\bhttp-equiv\s*=\s*["']?refresh["']?[^>]*\bcontent\s*=\s*["'][^"']*\burl\s*=\s*(?:https?:)?\/\//iu;
  assertion(!metaRefresh.test(source), `${relative} contains an external meta refresh`, findings);
  const networkPrimitive = /\b(?:fetch|WebSocket|EventSource|XMLHttpRequest|sendBeacon)\b/u;
  assertion(!networkPrimitive.test(source), `${relative} contains a network-request primitive`, findings);
  if (!isExactTrustedVendor) {
    verifyDestinationSinks(relative, source, findings);
  }

  const credentialLiteral =
    /\b(?:sk-[a-z0-9_-]{16,}|api[_-]?key\s*[:=]\s*["'][^"']+|bearer\s+[a-z0-9._~+/=-]{16,})/iu;
  assertion(!credentialLiteral.test(source), `${relative} contains a credential-like literal`, findings);

  if (relative.endsWith('.html')) {
    assertion(!/<script\b(?![^>]*\bsrc=)[^>]*>/iu.test(source), `${relative} contains inline script`, findings);
    assertion(!/\son[a-z]+\s*=/iu.test(source), `${relative} contains an inline event handler`, findings);
  }
}

async function verifyMarkers(manifest, findings) {
  const allSources = (
    await Promise.all(
      Object.keys(manifest.assets ?? {})
        .filter((relative) => /\.(?:css|html|js|svg|md)$/u.test(relative))
        .map((relative) => readFile(path.join(FIXTURE_ROOT, relative), 'utf8'))
    )
  ).join('\n');
  for (const fixture of manifest.fixtures ?? []) {
    for (const marker of fixture.markers ?? []) {
      assertion(allSources.includes(marker), `fixture marker ${marker} is absent from the asset tree`, findings);
    }
  }
}

async function verify(options = {}) {
  const source = await readFile(MANIFEST_PATH, 'utf8');
  const manifest = JSON.parse(source);
  const computed = await computeAssetManifest();

  if (options.write) {
    const updated = {
      ...manifest,
      assets: computed.assets,
      assetRootSha256: computed.assetRootSha256
    };
    await writeFile(MANIFEST_PATH, `${JSON.stringify(updated, null, 2)}\n`);
  }

  const current = options.write ? JSON.parse(await readFile(MANIFEST_PATH, 'utf8')) : manifest;
  const findings = [];
  verifyManifestShape(current, findings);
  assertion(
    JSON.stringify(current.assets) === JSON.stringify(computed.assets),
    'manifest asset hashes do not match the fixture tree; run node verify.mjs --write',
    findings
  );
  assertion(
    current.assetRootSha256 === computed.assetRootSha256,
    'manifest assetRootSha256 does not match the fixture tree',
    findings
  );

  for (const relative of Object.keys(computed.assets)) {
    if (/\.(?:css|html|js|json|md|svg|txt)$/u.test(relative)) {
      verifySourceSafety(relative, await readFile(path.join(FIXTURE_ROOT, relative), 'utf8'), findings);
    }
  }
  await verifyMarkers(current, findings);

  if (findings.length > 0) {
    throw new Error(`Safari fixture verification failed:\n- ${findings.join('\n- ')}`);
  }
  return {
    fixtureCount: current.fixtures.length,
    assetCount: Object.keys(computed.assets).length,
    assetRootSha256: computed.assetRootSha256
  };
}

async function main() {
  const argumentsList = process.argv.slice(2);
  if (argumentsList.some((argument) => argument !== '--write')) {
    throw new Error('Usage: node verify.mjs [--write]');
  }
  const result = await verify({ write: argumentsList.includes('--write') });
  process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}

export { computeAssetManifest, verify, verifySourceSafety };
