import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import crypto from 'node:crypto';
import {
  canonicalRepositoryKey,
  publicRepositoryKeys,
  requiresSnapshotHeader,
  verifyLinuxPublicRepository
} from './verify-linux-public-repository.mjs';

test('canonical routing keeps channel roots public and root evidence snapshot-addressed', () => {
  assert.equal(canonicalRepositoryKey('apt/dists/stable/InRelease', 'stable'), 'linux/apt/dists/stable/InRelease');
  assert.equal(canonicalRepositoryKey('apt/pool/main/o/openburnbar/a.deb', 'stable'), 'linux/apt/pool/main/o/openburnbar/a.deb');
  assert.equal(canonicalRepositoryKey('rpm/stable/x86_64/repodata/repomd.xml', 'stable'), 'linux/rpm/stable/x86_64/repodata/repomd.xml');
  assert.equal(canonicalRepositoryKey('apt/openburnbar-archive-keyring.gpg', 'stable'), 'linux/apt/openburnbar-stable-archive-keyring.gpg');
  assert.equal(canonicalRepositoryKey('apt/openburnbar-archive-keyring.gpg', 'prerelease'), 'linux/apt/openburnbar-prerelease-archive-keyring.gpg');
  assert.equal(canonicalRepositoryKey('rpm/RPM-GPG-KEY-openburnbar', 'nightly'), 'linux/rpm/RPM-GPG-KEY-openburnbar-nightly');
  assert.equal(canonicalRepositoryKey('rpm/openburnbar-stable.repo', 'stable'), 'linux/rpm/openburnbar-stable.repo');
  assert.equal(canonicalRepositoryKey('repository-closure.json', 'stable'), null);
  assert.equal(canonicalRepositoryKey('apt/openburnbar-stable.sources', 'stable'), 'linux/apt/openburnbar-stable.sources');
  assert.equal(requiresSnapshotHeader('apt/openburnbar-archive-keyring.gpg', 'stable'), true);
  assert.equal(requiresSnapshotHeader('apt/openburnbar-stable.sources', 'stable'), true);
  assert.equal(requiresSnapshotHeader('apt/dists/stable/InRelease', 'stable'), true);
  assert.equal(requiresSnapshotHeader(`apt/dists/stable/main/binary-amd64/by-hash/SHA256/${'a'.repeat(64)}`, 'stable'), false);
  assert.equal(requiresSnapshotHeader('rpm/stable/x86_64/repodata/repomd.xml.asc', 'stable'), true);
  assert.equal(requiresSnapshotHeader('rpm/stable/x86_64/repodata/a-primary.xml.gz', 'stable'), false);
  assert.deepEqual(publicRepositoryKeys('apt/openburnbar-archive-keyring.gpg', 'stable'), [
    'linux/apt/openburnbar-stable-archive-keyring.gpg',
    'linux/apt/openburnbar-archive-keyring.gpg'
  ]);
  assert.deepEqual(publicRepositoryKeys('rpm/RPM-GPG-KEY-openburnbar', 'stable'), [
    'linux/rpm/RPM-GPG-KEY-openburnbar-stable',
    'linux/rpm/RPM-GPG-KEY-openburnbar'
  ]);
  assert.deepEqual(publicRepositoryKeys('apt/openburnbar-archive-keyring.gpg', 'prerelease'), [
    'linux/apt/openburnbar-prerelease-archive-keyring.gpg'
  ]);
  assert.deepEqual(publicRepositoryKeys('repository-closure.json', 'stable'), []);
});

test('stable public verifier checks exact legacy and channel-qualified bootstrap key aliases', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-public-bootstrap-aliases-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const closure = `${JSON.stringify({ schemaVersion: 1, channel: 'stable', version: '1.2.3', gitCommit: 'a'.repeat(40) })}\n`;
  fs.writeFileSync(path.join(root, 'repository-closure.json'), closure);
  fs.mkdirSync(path.join(root, 'apt'), { recursive: true });
  fs.mkdirSync(path.join(root, 'rpm'), { recursive: true });
  fs.writeFileSync(path.join(root, 'apt/openburnbar-archive-keyring.gpg'), 'apt key\n');
  fs.writeFileSync(path.join(root, 'rpm/RPM-GPG-KEY-openburnbar'), 'rpm key\n');
  const snapshotId = crypto.createHash('sha256').update(closure).digest('hex');
  const requested = [];

  const result = await verifyLinuxPublicRepository({
    repositoryRoot: root,
    baseUrl: 'https://downloads.example',
    fetchImpl: async (url) => {
      const pathname = new URL(url).pathname;
      requested.push(pathname);
      const body = pathname.includes('/apt/') ? 'apt key\n'
        : pathname.includes('/rpm/') ? 'rpm key\n' : closure;
      return new Response(body, {
        status: 200,
        headers: pathname.includes('/apt/') || pathname.includes('/rpm/')
          ? { 'X-OpenBurnBar-Repository-Snapshot': snapshotId }
          : {}
      });
    }
  });

  assert.equal(result.passed, true);
  assert.equal(result.objectCount, 5);
  assert.equal(result.verified, 5);
  for (const pathname of [
    '/linux/apt/openburnbar-stable-archive-keyring.gpg',
    '/linux/apt/openburnbar-archive-keyring.gpg',
    '/linux/rpm/RPM-GPG-KEY-openburnbar-stable',
    '/linux/rpm/RPM-GPG-KEY-openburnbar'
  ]) assert.ok(requested.includes(pathname), pathname);

  const drifted = await verifyLinuxPublicRepository({
    repositoryRoot: root,
    baseUrl: 'https://downloads.example',
    fetchImpl: async (url) => {
      const pathname = new URL(url).pathname;
      const isBootstrap = pathname.includes('/apt/') || pathname.includes('/rpm/');
      const body = pathname === '/linux/apt/openburnbar-archive-keyring.gpg'
        ? 'drifted legacy apt key\n'
        : pathname.includes('/apt/') ? 'apt key\n'
          : pathname.includes('/rpm/') ? 'rpm key\n' : closure;
      return new Response(body, {
        status: 200,
        headers: isBootstrap ? { 'X-OpenBurnBar-Repository-Snapshot': snapshotId } : {}
      });
    }
  });
  assert.equal(drifted.passed, false);
  assert.match(drifted.failures.join('\n'), /linux\/apt\/openburnbar-archive-keyring\.gpg: byte mismatch/u);
});

test('public verifier detects exact byte drift across canonical and snapshot paths', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-public-repository-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const closure = `${JSON.stringify({ schemaVersion: 1, channel: 'stable', version: '1.2.3', gitCommit: 'a'.repeat(40) })}\n`;
  fs.writeFileSync(path.join(root, 'repository-closure.json'), closure);
  fs.mkdirSync(path.join(root, 'apt/dists/stable'), { recursive: true });
  fs.writeFileSync(path.join(root, 'apt/dists/stable/InRelease'), 'signed metadata\n');
  const snapshotId = crypto.createHash('sha256').update(closure).digest('hex');
  let drift = false;
  const result = await verifyLinuxPublicRepository({ repositoryRoot: root, baseUrl: 'https://downloads.example', fetchImpl: async (url) => {
    const pathname = new URL(url).pathname;
    const bytes = pathname.endsWith('/InRelease') ? (drift ? 'bad\n' : 'signed metadata\n') : closure;
    return new Response(bytes, { status: 200, headers: pathname.endsWith('/InRelease')
      ? { 'X-OpenBurnBar-Repository-Snapshot': snapshotId } : {} });
  } });
  assert.equal(result.passed, true);
  drift = true;
  const failed = await verifyLinuxPublicRepository({ repositoryRoot: root, baseUrl: 'https://downloads.example', fetchImpl: async (url) => {
    const bytes = new URL(url).pathname.endsWith('/InRelease') ? 'bad\n' : closure;
    return new Response(bytes, { status: 200, headers: new URL(url).pathname.endsWith('/InRelease')
      ? { 'X-OpenBurnBar-Repository-Snapshot': snapshotId } : {} });
  } });
  assert.equal(failed.passed, false);
  assert.match(failed.failures[0], /byte mismatch/u);
});

test('public verifier rejects an exact but wrong 64-character pointer snapshot header', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-public-snapshot-header-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const closure = `${JSON.stringify({ schemaVersion: 1, channel: 'stable', version: '1.2.3', gitCommit: 'a'.repeat(40) })}\n`;
  fs.writeFileSync(path.join(root, 'repository-closure.json'), closure);
  fs.mkdirSync(path.join(root, 'apt'), { recursive: true });
  fs.writeFileSync(path.join(root, 'apt/openburnbar-archive-keyring.gpg'), 'key bytes\n');

  const result = await verifyLinuxPublicRepository({
    repositoryRoot: root,
    baseUrl: 'https://downloads.example',
    fetchImpl: async (url) => {
      const isKey = new URL(url).pathname.endsWith('-archive-keyring.gpg');
      return new Response(isKey ? 'key bytes\n' : closure, {
        status: 200,
        headers: isKey ? { 'X-OpenBurnBar-Repository-Snapshot': 'f'.repeat(64) } : {}
      });
    }
  });

  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /snapshot header mismatch/u);
  assert.match(result.failures.join('\n'), new RegExp('f{64}', 'u'));
});
