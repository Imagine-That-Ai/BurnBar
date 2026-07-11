#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {
  fileSize,
  readJson,
  relative,
  repoRoot,
  sha256,
  writeJson
} from './lib/linux-release-common.mjs';

const argv = process.argv.slice(2);
const value = (flag) => {
  const index = argv.indexOf(flag);
  return index >= 0 ? argv[index + 1]?.trim() : null;
};
const version = value('--version');
const channel = value('--channel');
const releaseOut = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-release'));
if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(version ?? '')) {
  throw new Error('repository finalization requires strict --version X.Y.Z');
}
if (!['stable', 'prerelease', 'nightly'].includes(channel)) {
  throw new Error('repository finalization requires --channel stable, prerelease, or nightly');
}

const packageClosurePath = path.join(releaseOut, 'package-closure.json');
const packageClosure = readJson(packageClosurePath);
if (packageClosure.schemaVersion !== 3 || packageClosure.version !== version || packageClosure.git?.commit == null) {
  throw new Error('package closure is missing or does not match repository finalization');
}
const provenanceRelative = packageClosure.sidecars?.provenancePredicate?.file;
if (!provenanceRelative) throw new Error('package closure has no provenance predicate');
const provenancePath = confinedFile(provenanceRelative);
const updateFeedPath = confinedFile(packageClosure.sidecars?.updateFeed?.file);
const repositoryClosurePath = path.join(releaseOut, 'repositories/repository-closure.json');
const repositorySignaturePath = `${repositoryClosurePath}.asc`;
const lifecyclePath = path.join(releaseOut, 'repositories/repository-lifecycle.json');
for (const required of [provenancePath, updateFeedPath, repositoryClosurePath, repositorySignaturePath, lifecyclePath]) {
  if (!required || !fs.existsSync(required) || !fs.statSync(required).isFile()) {
    throw new Error(`repository finalization input is missing: ${required ?? '(outside repository)'}`);
  }
}
const repositoryClosure = readJson(repositoryClosurePath);
const lifecycle = readJson(lifecyclePath);
const updateFeed = readJson(updateFeedPath);
if (repositoryClosure.version !== version || repositoryClosure.channel !== channel
    || repositoryClosure.gitCommit !== packageClosure.git.commit) {
  throw new Error('repository closure is not bound to the package closure identity');
}
if (updateFeed.version !== version || updateFeed.channel !== channel
    || updateFeed.gitCommit !== packageClosure.git.commit) {
  throw new Error('repository channel is not bound to the signed update feed identity');
}
if (lifecycle.version !== version || lifecycle.channel !== channel || lifecycle.passed !== true) {
  throw new Error('repository lifecycle evidence is not green for this version/channel');
}
const expectedLifecycle = {
  architectures: ['aarch64', 'x86_64'],
  operations: ['install', 'remove'],
  apt: [
    { passed: true, architecture: 'amd64', platform: 'linux/amd64' },
    { passed: true, architecture: 'arm64', platform: 'linux/arm64' }
  ],
  rpm: [
    { passed: true, architecture: 'x86_64', platform: 'linux/amd64' },
    { passed: true, architecture: 'aarch64', platform: 'linux/arm64' }
  ]
};
for (const [key, expected] of Object.entries(expectedLifecycle)) {
  if (JSON.stringify(lifecycle[key]) !== JSON.stringify(expected)) {
    throw new Error(`repository lifecycle evidence has incomplete ${key} coverage`);
  }
}
if (JSON.stringify(repositoryClosure.lifecycleRequired) !== JSON.stringify({
  architectures: expectedLifecycle.architectures,
  operations: expectedLifecycle.operations,
  packageManagers: ['apt', 'dnf']
})) {
  throw new Error('repository closure lifecycle requirements are not canonical');
}
if (lifecycle.repositoryClosureSha256 !== sha256(repositoryClosurePath)) {
  throw new Error('repository lifecycle evidence does not bind the repository closure');
}

const record = (file) => ({ file: relative(file), sha256: sha256(file), size: fileSize(file) });
const repositoryRecords = {
  repositoryClosure: record(repositoryClosurePath),
  repositoryClosureSignature: record(repositorySignaturePath),
  repositoryLifecycle: record(lifecyclePath)
};
const provenance = readJson(provenancePath);
provenance.repositories = {
  packageSetRootSha256: repositoryClosure.packageSetRootSha256,
  signingFingerprint: repositoryClosure.signing?.fingerprint,
  signingSubkeyFingerprint: repositoryClosure.signing?.signingFingerprint,
  ...repositoryRecords
};
writeJson(provenancePath, provenance);

packageClosure.repositoryPackageSetRootSha256 = repositoryClosure.packageSetRootSha256;
packageClosure.sidecars = {
  ...packageClosure.sidecars,
  ...repositoryRecords,
  provenancePredicate: record(provenancePath)
};
writeJson(packageClosurePath, packageClosure);

console.log(JSON.stringify({
  packageClosure: relative(packageClosurePath),
  provenancePredicate: relative(provenancePath),
  repositories: repositoryRecords
}, null, 2));

function confinedFile(relativePath) {
  if (typeof relativePath !== 'string' || !relativePath || path.isAbsolute(relativePath)) return null;
  const lexical = path.resolve(repoRoot, relativePath);
  if (lexical !== repoRoot && !lexical.startsWith(`${repoRoot}${path.sep}`)) return null;
  if (!fs.existsSync(lexical)) return null;
  const real = fs.realpathSync(lexical);
  return (real === repoRoot || real.startsWith(`${repoRoot}${path.sep}`)) ? real : null;
}
