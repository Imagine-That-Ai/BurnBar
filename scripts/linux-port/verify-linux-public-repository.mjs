#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { repositorySnapshotIdentity } from './lib/linux-repository-activation.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

export function canonicalRepositoryKey(relative, channel) {
  if (relative === 'repository-closure.json' || relative === 'repository-closure.json.asc'
      || relative === 'repository-lifecycle.json') return null;
  if (relative === 'apt/openburnbar-archive-keyring.gpg') {
    return `linux/apt/openburnbar-${channel}-archive-keyring.gpg`;
  }
  if (relative === 'rpm/RPM-GPG-KEY-openburnbar') {
    return `linux/rpm/RPM-GPG-KEY-openburnbar-${channel}`;
  }
  if (relative.startsWith(`apt/dists/${channel}/`) || relative.startsWith('apt/pool/')
      || relative === `apt/openburnbar-${channel}.sources`) return `linux/${relative}`;
  if (relative.startsWith(`rpm/${channel}/`)
      || relative === `rpm/openburnbar-${channel}.repo`) return `linux/${relative}`;
  return null;
}

export function requiresSnapshotHeader(relative, channel) {
  if (relative === 'apt/openburnbar-archive-keyring.gpg'
      || relative === `apt/openburnbar-${channel}.sources`
      || relative === 'rpm/RPM-GPG-KEY-openburnbar'
      || relative === `rpm/openburnbar-${channel}.repo`) return true;
  if (relative.startsWith(`apt/dists/${channel}/`) && !relative.includes('/by-hash/')) return true;
  return /^rpm\/(stable|prerelease|nightly)\/(aarch64|x86_64)\/repodata\/repomd\.xml(?:\.asc)?$/u.test(relative);
}

export function publicRepositoryKeys(relative, channel) {
  const canonical = canonicalRepositoryKey(relative, channel);
  if (!canonical) return [];
  const keys = [canonical];
  if (channel === 'stable' && relative === 'apt/openburnbar-archive-keyring.gpg') {
    keys.push('linux/apt/openburnbar-archive-keyring.gpg');
  }
  if (channel === 'stable' && relative === 'rpm/RPM-GPG-KEY-openburnbar') {
    keys.push('linux/rpm/RPM-GPG-KEY-openburnbar');
  }
  return keys;
}

export async function verifyLinuxPublicRepository({ repositoryRoot, baseUrl, fetchImpl = fetch }) {
  const closurePath = path.join(repositoryRoot, 'repository-closure.json');
  const identity = repositorySnapshotIdentity(closurePath);
  const files = walkFiles(repositoryRoot);
  const targets = files.flatMap((file) => {
    const relative = path.relative(repositoryRoot, file).split(path.sep).join('/');
    const publicKeys = publicRepositoryKeys(relative, identity.channel);
    const keys = publicKeys.length > 0
      ? publicKeys
      : [`linux/repository-snapshots/${identity.channel}/${identity.snapshotId}/${relative}`];
    return keys.map((key) => ({
      file,
      relative,
      key
    }));
  });
  const failures = [];
  let verified = 0;
  for (const { file, relative, key } of targets) {
    const canonicalKey = canonicalRepositoryKey(relative, identity.channel);
    const url = new URL(key, `${baseUrl.replace(/\/$/u, '')}/`);
    try {
      const response = await fetchImpl(url, {
        headers: { 'Cache-Control': 'no-cache' },
        redirect: 'error'
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      if (canonicalKey && requiresSnapshotHeader(relative, identity.channel)) {
        const servedSnapshot = response.headers.get('x-openburnbar-repository-snapshot');
        if (servedSnapshot !== identity.snapshotId) {
          throw new Error(`snapshot header mismatch: expected ${identity.snapshotId}, received ${servedSnapshot ?? 'missing'}`);
        }
      }
      const actual = Buffer.from(await response.arrayBuffer());
      const expected = fs.readFileSync(file);
      if (!actual.equals(expected)) throw new Error('byte mismatch');
      verified += 1;
    } catch (error) {
      failures.push(`${key}: ${error.message}`);
    }
  }
  return { schemaVersion: 1, ...identity, objectCount: targets.length, verified, passed: failures.length === 0, failures };
}

function walkFiles(root) {
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const full = path.join(root, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`repository contains a symbolic link: ${full}`);
    if (entry.isDirectory()) files.push(...walkFiles(full));
    else if (entry.isFile()) files.push(full);
    else throw new Error(`repository contains an unsupported filesystem entry: ${full}`);
  }
  return files.sort();
}

async function main() {
  const releaseOut = process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-release');
  const result = await verifyLinuxPublicRepository({
    repositoryRoot: process.env.OPENBURNBAR_LINUX_REPOSITORY_OUT ?? path.join(releaseOut, 'repositories'),
    baseUrl: process.env.OPENBURNBAR_R2_PUBLIC_BASE_URL ?? 'https://downloads.burnbar.ai'
  });
  const output = `${JSON.stringify({ ...result, verifiedAt: new Date().toISOString() }, null, 2)}\n`;
  const outputPath = process.env.OPENBURNBAR_LINUX_PUBLIC_REPOSITORY_RECEIPT;
  if (outputPath) fs.writeFileSync(outputPath, output, { flag: 'wx' });
  process.stdout.write(output);
  if (!result.passed) process.exitCode = 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
