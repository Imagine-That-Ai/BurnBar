import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { readLinuxDesktopRustSource } from './lib/linux-desktop-rust-source.mjs';
import { repoRoot } from './lib/linux-release-common.mjs';

const read = (relativePath) => fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
const catalog = JSON.parse(read('packaging/linux/runtime-capability-catalog.json'));
const schema = JSON.parse(read('schemas/linux-runtime-capability-manifest.schema.json'));
const routesSource = read('apps/linux-desktop/src/routes.ts');
const runtimeSource = read('apps/linux-desktop/src/runtimeCapabilities.ts');
const rustSource = readLinuxDesktopRustSource(repoRoot);
const bridgeSource = read('apps/linux-desktop/src/tauriBridge.ts');
const surfaceSource = read('apps/linux-desktop/src/surfaces/SurfaceRouter.tsx');

const KNOWN_DOMAINS = new Set(['product', 'platform', 'security', 'delivery']);
const KNOWN_EVALUATORS = new Set([
  'always',
  'daemon',
  'gateway',
  'trusted-cli',
  'secret-service',
  'kwallet',
  'portal',
  'media',
  'tray',
  'x11-overlay',
  'computer-use-system',
  'unavailable'
]);

function sourceRouteRequirements() {
  const entries = [...routesSource.matchAll(
    /\{\s*id:\s*'([^']+)'[\s\S]*?requiredCapability:\s*'([^']+)'\s*\}/g
  )];
  return new Map(entries.map((entry) => [entry[1], entry[2]]));
}

function catalogRouteRequirements() {
  const entries = [];
  for (const capability of catalog.capabilities) {
    if (capability.route) entries.push([capability.route, capability.id]);
    for (const route of capability.additionalRoutes ?? []) entries.push([route, capability.id]);
  }
  return entries;
}

test('runtime capability catalog is complete, unique, and explicit', () => {
  assert.equal(catalog.schemaVersion, 1);
  assert.match(catalog.catalogVersion, /^\d{4}-\d{2}-\d{2}$/);
  assert.ok(Array.isArray(catalog.capabilities));
  assert.ok(catalog.capabilities.length >= 26);

  const ids = new Set();
  for (const capability of catalog.capabilities) {
    assert.match(capability.id, /^[a-z0-9]+(?:[.-][a-z0-9]+)+$/);
    assert.equal(ids.has(capability.id), false, `duplicate capability ${capability.id}`);
    ids.add(capability.id);
    assert.equal(KNOWN_DOMAINS.has(capability.domain), true, capability.id);
    assert.equal(KNOWN_EVALUATORS.has(capability.evaluator), true, capability.id);
    if (capability.evaluator !== 'always') {
      assert.ok(capability.unavailableReason.trim().length > 0, capability.id);
      assert.ok(capability.substitute.trim().length > 0, capability.id);
    }
    if (capability.additionalRoutes) {
      assert.ok(Array.isArray(capability.additionalRoutes), capability.id);
      assert.equal(new Set(capability.additionalRoutes).size, capability.additionalRoutes.length);
    }
  }

  const idArray = runtimeSource.match(/RUNTIME_CAPABILITY_IDS\s*=\s*\[([\s\S]*?)\]\s*as const/)?.[1];
  assert.ok(idArray, 'renderer capability ID array is missing');
  const rendererIDs = new Set([...idArray.matchAll(/'([^']+)'/g)].map((match) => match[1]));
  assert.deepEqual(rendererIDs, ids);
});

test('every Linux route has exactly one matching catalog requirement', () => {
  const sourceRequirements = sourceRouteRequirements();
  assert.equal(sourceRequirements.size, 19);
  const catalogEntries = catalogRouteRequirements();
  const catalogRoutes = catalogEntries.map(([route]) => route);
  assert.equal(new Set(catalogRoutes).size, catalogRoutes.length, 'catalog route assigned twice');
  assert.equal(catalogEntries.length, sourceRequirements.size);
  for (const [route, capability] of catalogEntries) {
    assert.equal(sourceRequirements.get(route), capability, route);
  }
});

test('manifest schema and both runtime boundaries remain fail closed', () => {
  assert.equal(schema.properties.schemaVersion.const, 1);
  assert.equal(schema.additionalProperties, false);
  assert.equal(schema.properties.capabilities.items.additionalProperties, false);
  assert.deepEqual(schema.properties.capabilities.items.properties.state.enum, [
    'available',
    'degraded',
    'unavailable',
    'blocked'
  ]);
  assert.ok(schema.required.includes('capabilities'));

  for (const marker of [
    'include_str!(',
    'packaging/linux/runtime-capability-catalog.json',
    'fn runtime_capabilities()',
    'runtime_capability_unknown_evaluator',
    'runtime_capability_schema_unsupported'
  ]) assert.ok(rustSource.includes(marker), marker);
  for (const evaluator of KNOWN_EVALUATORS) {
    assert.ok(rustSource.includes(`"${evaluator}"`), `native evaluator missing ${evaluator}`);
  }
  for (const marker of [
    "invoke<RawJsonValue>('runtime_capabilities')",
    'decodeRuntimeCapabilityManifest',
    'runtime_capability_manifest_missing_ids'
  ]) assert.ok(`${bridgeSource}\n${runtimeSource}`.includes(marker), marker);
  for (const marker of [
    'capabilityBlocksSurface',
    'capabilityError',
    'capability-boundary',
    'findRuntimeCapability'
  ]) assert.ok(surfaceSource.includes(marker), marker);
});
