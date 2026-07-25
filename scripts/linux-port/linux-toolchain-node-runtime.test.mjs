import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { repoRoot } from './lib/linux-release-common.mjs';

const read = (relativePath) => fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
const toolchain = read('tools/linux-toolchain/Dockerfile');
const smoke = read('tools/linux-toolchain/smoke.sh');
const desktopPackage = JSON.parse(read('apps/linux-desktop/package.json'));
const releaseToolsPackage = JSON.parse(read('scripts/linux-port/package.json'));

function parseVersion(value) {
  const match = String(value).match(/^(?:v)?(\d+)\.(\d+)\.(\d+)$/u);
  assert.ok(match, `expected strict semver, got ${value}`);
  return match.slice(1).map(Number);
}

function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  for (let index = 0; index < a.length; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}

test('Linux toolchain pins an official Node runtime compatible with both package contracts', () => {
  const version = toolchain.match(/^ARG NODE_VERSION=([^\n]+)$/mu)?.[1];
  assert.ok(version, 'toolchain must pin NODE_VERSION');
  assert.ok(compareVersions(version, '20.18.0') >= 0, `Node ${version} is below the desktop contract`);
  assert.ok(compareVersions(version, '22.0.0') >= 0, `Node ${version} is below the release-tools contract`);
  assert.match(desktopPackage.engines.node, />=20\.18\.0/u);
  assert.match(releaseToolsPackage.engines.node, />=22/u);

  for (const [arch, digest] of [
    ['x64', toolchain.match(/^ARG NODE_X64_SHA256=([^\n]+)$/mu)?.[1]],
    ['arm64', toolchain.match(/^ARG NODE_ARM64_SHA256=([^\n]+)$/mu)?.[1]]
  ]) {
    assert.match(digest ?? '', /^[a-f0-9]{64}$/u, `${arch} Node archive must have a SHA-256 pin`);
  }
  assert.match(toolchain, /node-v\$\{NODE_VERSION\}-linux-\$\{node_arch\}\.tar\.xz/u);
  assert.match(toolchain, /https:\/\/nodejs\.org\/dist\/v\$\{NODE_VERSION\}/u);
  assert.match(toolchain, /sha256sum -c -/u);
  assert.match(toolchain, /test "\$\(node --version\)" = "v\$\{NODE_VERSION\}"/u);
});

test('Linux toolchain does not reintroduce Noble Node 18 packages', () => {
  const aptPackages = toolchain.match(/apt-get[\s\S]*?install -y --no-install-recommends([\s\S]*?)&& rm -rf \/var\/lib\/apt\/lists\//u)?.[1];
  assert.ok(aptPackages, 'could not locate toolchain apt package list');
  assert.doesNotMatch(aptPackages, /\bnodejs\b/u);
  assert.doesNotMatch(aptPackages, /\bnpm\b/u);
  assert.match(toolchain, /dpkg --print-architecture/u);
  assert.match(toolchain, /amd64\) node_arch=x64/u);
  assert.match(toolchain, /arm64\) node_arch=arm64/u);
});

test('Linux toolchain includes runtime dependencies required by Debian package smoke', () => {
  const aptPackages = toolchain.match(/apt-get[\s\S]*?install -y --no-install-recommends([\s\S]*?)&& rm -rf \/var\/lib\/apt\/lists\//u)?.[1];
  assert.ok(aptPackages, 'could not locate toolchain apt package list');
  assert.match(aptPackages, /\n\s+ibus \\\n/u, 'Debian package smoke requires the declared IBus runtime');
});

test('Linux toolchain normalizes Ubuntu package mirrors to HTTPS', () => {
  for (const host of ['ports.ubuntu.com', 'archive.ubuntu.com', 'security.ubuntu.com']) {
    assert.ok(
      toolchain.includes(`-e 's|http://${host}|https://${host}|g'`),
      `${host} mirror rewrite must replace the exact HTTP origin with HTTPS`
    );
  }
});

test('toolchain smoke reports the runtime actually used by release builds', () => {
  assert.match(smoke, /node --version/u);
  assert.match(smoke, /npm --version/u);
  assert.match(smoke, /node-runtime=%s\\nnpm-runtime=%s/u);
  assert.doesNotMatch(smoke, /\n\s*nodejs \\\n/u);
  assert.doesNotMatch(smoke, /\n\s*npm \\\n/u);
});
