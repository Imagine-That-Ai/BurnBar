import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const uploadScript = path.join(repoRoot, 'scripts/upload-linux-downloads-r2.sh');
const version = '1.2.3';
const releasePrefix = `linux/releases/linux-v${version}`;

test('R2 publisher uploads immutable release bytes before metadata and verifies every public object', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-r2-publish-test-'));
  try {
    const releaseOut = path.join(root, 'release');
    const artifacts = path.join(releaseOut, 'artifacts');
    const sidecars = path.join(releaseOut, 'sidecars');
    const repositories = path.join(releaseOut, 'repositories');
    const bin = path.join(root, 'bin');
    const objectRoot = path.join(root, 'objects');
    const log = path.join(root, 'put.log');
    for (const directory of [artifacts, sidecars, repositories, bin, objectRoot]) {
      fs.mkdirSync(directory, { recursive: true });
    }

    const artifactNames = [];
    for (const architecture of ['aarch64', 'x86_64']) {
      for (const extension of ['AppImage', 'deb', 'rpm']) artifactNames.push(`OpenBurnBar-${version}-${architecture}.${extension}`);
      artifactNames.push(`openburnbar-daemon-${version}-${architecture}`);
    }
    for (const name of artifactNames) {
      fs.writeFileSync(path.join(artifacts, name), `artifact:${name}\n`);
      fs.writeFileSync(path.join(sidecars, `${name}.ed25519.sig`), `signature:${name}\n`);
    }
    fs.writeFileSync(path.join(sidecars, 'latest-linux.json.ed25519.sig'), 'feed-signature\n');

    const publicBase = 'https://downloads.burnbar.ai';
    const feed = {
      version,
      signature: { url: `${publicBase}/${releasePrefix}/latest-linux.json.ed25519.sig` },
      artifacts: artifactNames.map((name) => ({
        url: `${publicBase}/${releasePrefix}/${name}`,
        signatureUrl: `${publicBase}/${releasePrefix}/${name}.ed25519.sig`
      }))
    };
    fs.writeFileSync(path.join(releaseOut, 'latest-linux.draft.json'), `${JSON.stringify(feed)}\n`);
    fs.writeFileSync(path.join(releaseOut, 'release-verification.json'), `${JSON.stringify({
      phase: 'final', passed: true, failures: []
    })}\n`);

    for (const relative of [
      'apt/pool/main/o/openburnbar/OpenBurnBar_1.2.3_amd64.deb',
      'apt/pool/main/o/openburnbar/OpenBurnBar_1.2.3_arm64.deb',
      'rpm/prerelease/x86_64/OpenBurnBar-1.2.3-1.x86_64.rpm',
      'rpm/prerelease/aarch64/OpenBurnBar-1.2.3-1.aarch64.rpm',
      'apt/dists/prerelease/main/binary-amd64/by-hash/SHA256/abc',
      'apt/dists/prerelease/Release.gpg',
      'apt/dists/prerelease/Release',
      'apt/dists/prerelease/InRelease',
      'rpm/prerelease/x86_64/repodata/abc-primary.xml.gz',
      'rpm/prerelease/x86_64/repodata/repomd.xml.asc',
      'rpm/prerelease/x86_64/repodata/repomd.xml',
      'rpm/prerelease/aarch64/repodata/repomd.xml.asc',
      'rpm/prerelease/aarch64/repodata/repomd.xml',
      'repository-lifecycle.json',
      'repository-closure.json.asc',
      'repository-closure.json'
    ]) {
      const file = path.join(repositories, relative);
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, `${relative}\n`);
    }

    installFakeCommands({ bin, objectRoot, log });
    const result = spawnSync('bash', [uploadScript], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        REAL_NODE: process.execPath,
        FAKE_R2_ROOT: objectRoot,
        FAKE_R2_LOG: log,
        OPENBURNBAR_LINUX_RELEASE_OUT: releaseOut,
        OPENBURNBAR_R2_BUCKET: 'test-bucket',
        OPENBURNBAR_R2_PUBLIC_BASE_URL: publicBase,
        WRANGLER_BIN: path.join(bin, 'wrangler')
      }
    });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);

    const keys = fs.readFileSync(log, 'utf8').trim().split('\n');
    assert.equal(keys.length, new Set(keys).size, 'publisher must not overwrite an object within one transaction');
    for (const name of [...artifactNames, ...artifactNames.map((name) => `${name}.ed25519.sig`), 'latest-linux.json.ed25519.sig']) {
      assert.ok(keys.includes(`${releasePrefix}/${name}`), name);
    }
    assert.ok(keys.indexOf(`${releasePrefix}/${artifactNames[0]}`) < keys.indexOf('linux/apt/dists/prerelease/Release'));
    assert.ok(keys.indexOf('linux/rpm/prerelease/x86_64/repodata/repomd.xml.asc')
      < keys.indexOf('linux/rpm/prerelease/x86_64/repodata/repomd.xml'));
    assert.ok(keys.indexOf('linux/repository-closure.json.asc')
      < keys.indexOf('linux/repository-closure.json'));
    assert.ok(keys.indexOf('latest-linux.json.ed25519.sig') < keys.indexOf('latest-linux.json'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

function installFakeCommands({ bin, objectRoot, log }) {
  const write = (name, source) => fs.writeFileSync(path.join(bin, name), `#!${process.execPath}\n${source}\n`, { mode: 0o755 });
  write('wrangler', `
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const key = args[3].slice(args[3].indexOf('/') + 1);
const source = args[args.indexOf('--file') + 1];
const destination = path.join(process.env.FAKE_R2_ROOT, key);
fs.mkdirSync(path.dirname(destination), { recursive: true });
fs.copyFileSync(source, destination);
fs.appendFileSync(process.env.FAKE_R2_LOG, key + '\\n');
`);
  write('curl', `
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const destination = args[args.indexOf('-o') + 1];
const url = new URL(args.find((value) => value.startsWith('https://')));
fs.copyFileSync(path.join(process.env.FAKE_R2_ROOT, url.pathname.startsWith('/') ? url.pathname.slice(1) : url.pathname), destination);
`);
  write('openssl', 'process.exit(0);');
  fs.writeFileSync(path.join(bin, 'node'), `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == *check-linux-update-feed.mjs ]]; then exit 0; fi
exec "$REAL_NODE" "$@"
`, { mode: 0o755 });
}
