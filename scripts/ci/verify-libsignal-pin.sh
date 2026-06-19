#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

network="false"
if [[ "${1:-}" == "--network" ]]; then
  network="true"
  shift
fi

if [[ $# -ne 0 ]]; then
  echo "Usage: scripts/ci/verify-libsignal-pin.sh [--network]" >&2
  exit 2
fi

node - "$network" <<'NODE'
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');

const network = process.argv[2] === 'true';

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

function requireString(value, path) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${path} must be a non-empty string`);
  }
  return value;
}

function readJSON(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}

function curl(url) {
  return execFileSync('curl', ['-fsSL', url], { encoding: 'utf8' });
}

function xmlTag(xml, tag, label) {
  const match = xml.match(new RegExp(`<${tag}>([^<]+)</${tag}>`));
  if (!match) fail(`${label} is missing <${tag}>`);
  return match[1];
}

function xmlTagValues(xml, tag) {
  return Array.from(xml.matchAll(new RegExp(`<${tag}>([^<]+)</${tag}>`, 'g')), (match) => match[1]);
}

const manifest = readJSON('third_party/libsignal/manifest.json');
const readiness = readJSON('third_party/libsignal/runtime-readiness.json');
const bridgePackage = readJSON('packages/libsignal-bridge/package.json');
const bridgeLock = readJSON('packages/libsignal-bridge/package-lock.json');

const upstreamRepository = requireString(manifest.upstreamRepository, 'manifest.upstreamRepository');
const pinnedTag = requireString(manifest.pinnedTag, 'manifest.pinnedTag');
const pinnedTagObject = requireString(manifest.pinnedTagObject, 'manifest.pinnedTagObject');
const pinnedCommit = requireString(manifest.pinnedCommit, 'manifest.pinnedCommit');
const nodeArtifact = manifest.artifacts?.node ?? {};
const nodePackage = requireString(nodeArtifact.package, 'manifest.artifacts.node.package');
const nodeVersion = requireString(nodeArtifact.version, 'manifest.artifacts.node.version');
const nodeIntegrity = requireString(nodeArtifact.integrity, 'manifest.artifacts.node.integrity');

if (manifest.license !== 'AGPL-3.0-only') fail('manifest.license must be AGPL-3.0-only');
if (readiness.officialLibsignalPin?.tag !== pinnedTag) fail('runtime-readiness tag does not match manifest');
if (readiness.officialLibsignalPin?.tagObject !== pinnedTagObject) fail('runtime-readiness tag object does not match manifest');
if (readiness.officialLibsignalPin?.commit !== pinnedCommit) fail('runtime-readiness commit does not match manifest');
if (bridgePackage.dependencies?.[nodePackage] !== nodeVersion) {
  fail(`packages/libsignal-bridge dependency ${nodePackage} must be ${nodeVersion}`);
}

const lockedNode = bridgeLock.packages?.[`node_modules/${nodePackage}`];
if (!lockedNode) fail(`package-lock is missing node_modules/${nodePackage}`);
if (lockedNode.version !== nodeVersion) fail(`package-lock ${nodePackage} version ${lockedNode.version} != ${nodeVersion}`);
if (lockedNode.integrity !== nodeIntegrity) fail(`package-lock ${nodePackage} integrity drifted`);

const androidArtifacts = manifest.artifacts?.android;
if (!Array.isArray(androidArtifacts) || androidArtifacts.length === 0) {
  fail('manifest.artifacts.android must list official Signal Maven artifacts');
}
for (const artifact of androidArtifacts) {
  requireString(artifact.group, 'android artifact group');
  requireString(artifact.artifact, 'android artifact id');
  requireString(artifact.version, 'android artifact version');
  requireString(artifact.repository, 'android artifact repository');
  if (artifact.version !== nodeVersion) {
    fail(`${artifact.group}:${artifact.artifact} version ${artifact.version} != node ${nodeVersion}`);
  }
}

if (!network) {
  console.log('PASS: libsignal pin metadata is internally consistent');
  process.exit(0);
}

const tagRefs = execFileSync('git', [
  'ls-remote',
  '--tags',
  upstreamRepository,
  `refs/tags/${pinnedTag}`,
  `refs/tags/${pinnedTag}^{}`,
], { encoding: 'utf8' }).trim().split('\n').filter(Boolean);

const tagObjectLine = tagRefs.find((line) => line.endsWith(`refs/tags/${pinnedTag}`));
const peeledLine = tagRefs.find((line) => line.endsWith(`refs/tags/${pinnedTag}^{}`));
if (!tagObjectLine) fail(`upstream tag ${pinnedTag} was not found`);
if (!peeledLine) fail(`upstream tag ${pinnedTag} has no peeled commit ref`);
if (tagObjectLine.split(/\s+/)[0] !== pinnedTagObject) fail(`upstream tag object for ${pinnedTag} drifted`);
if (peeledLine.split(/\s+/)[0] !== pinnedCommit) fail(`upstream peeled commit for ${pinnedTag} drifted`);

const npmMeta = JSON.parse(execFileSync('npm', [
  'view',
  `${nodePackage}@${nodeVersion}`,
  'version',
  'license',
  'dist.integrity',
  'repository.url',
  '--json',
], { encoding: 'utf8' }));
if (npmMeta.version !== nodeVersion) fail(`npm ${nodePackage}@${nodeVersion} resolved to ${npmMeta.version}`);
if (npmMeta.license !== 'AGPL-3.0-only') fail(`npm ${nodePackage} license is ${npmMeta.license}`);
if (npmMeta['dist.integrity'] !== nodeIntegrity) fail(`npm ${nodePackage} integrity drifted`);
if (!String(npmMeta['repository.url'] ?? '').includes('signalapp/libsignal')) {
  fail(`npm ${nodePackage} repository does not point at signalapp/libsignal`);
}

const npmLatest = JSON.parse(execFileSync('npm', ['view', nodePackage, 'version', '--json'], { encoding: 'utf8' }));
if (npmLatest !== nodeVersion) {
  console.warn(`WARN: npm latest ${nodePackage} is ${npmLatest}; manifest intentionally pins reviewed ${nodeVersion}`);
}

for (const artifact of androidArtifacts) {
  const base = artifact.repository.replace(/\/+$/, '');
  const groupPath = artifact.group.split('.').join('/');
  const metadataUrl = `${base}/${groupPath}/${artifact.artifact}/maven-metadata.xml`;
  const pomUrl = `${base}/${groupPath}/${artifact.artifact}/${artifact.version}/${artifact.artifact}-${artifact.version}.pom`;
  const metadata = curl(metadataUrl);
  const versions = xmlTagValues(metadata, 'version');
  if (!versions.includes(artifact.version)) {
    fail(`${artifact.group}:${artifact.artifact} metadata does not list pinned version ${artifact.version}`);
  }
  const latest = xmlTag(metadata, 'latest', metadataUrl);
  const release = xmlTag(metadata, 'release', metadataUrl);
  if (latest !== artifact.version || release !== artifact.version) {
    console.warn(
      `WARN: ${artifact.group}:${artifact.artifact} latest/release is ${latest}/${release}; ` +
      `manifest intentionally pins reviewed ${artifact.version}`,
    );
  }
  const pom = curl(pomUrl);
  if (xmlTag(pom, 'version', pomUrl) !== artifact.version) {
    fail(`${artifact.group}:${artifact.artifact} POM version does not match ${artifact.version}`);
  }
  if (!/AGPLv3|agpl-3\.0/i.test(pom)) {
    fail(`${artifact.group}:${artifact.artifact} POM does not advertise AGPL licensing`);
  }
}

console.log('PASS: libsignal pin is authentic against upstream Git, pinned npm metadata, and pinned Signal Maven artifacts');
NODE
