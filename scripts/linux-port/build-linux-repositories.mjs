#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildLinuxRepositories } from './lib/linux-repository.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const argv = process.argv.slice(2);
const value = (flag) => {
  const index = argv.indexOf(flag);
  return index >= 0 ? argv[index + 1]?.trim() : null;
};
const version = value('--version');
const channel = value('--channel');
const configPath = path.resolve(repoRoot, value('--config') ?? 'packaging/linux/distribution-channels.json');
const releaseOut = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-release'));
const privateKeyFile = value('--private-key-file');
const privateKeyStdin = argv.includes('--private-key-stdin');
const legacyEnvironment = 'OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY';

if (Object.hasOwn(process.env, legacyEnvironment)) {
  throw new Error(`${legacyEnvironment} is forbidden in the repository builder; pass the key only by stdin or a protected file`);
}
if (Boolean(privateKeyFile) === privateKeyStdin) {
  throw new Error('exactly one of --private-key-stdin or --private-key-file is required');
}
let privateKeyBytes;
if (privateKeyStdin) {
  privateKeyBytes = fs.readFileSync(0);
} else {
  const resolved = path.resolve(privateKeyFile);
  const stat = fs.lstatSync(resolved);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0) {
    throw new Error('--private-key-file must be a regular file with no group or other permissions');
  }
  privateKeyBytes = fs.readFileSync(resolved);
}
if (privateKeyBytes.length === 0 || privateKeyBytes.length > 1024 * 1024) {
  throw new Error('repository private key must be non-empty and at most 1 MiB');
}

let result;
try {
  result = buildLinuxRepositories({
    repoRoot,
    releaseOut,
    configPath,
    version,
    channel,
    privateKeyBytes
  });
} finally {
  privateKeyBytes.fill(0);
}
console.log(JSON.stringify({
  repositoryRoot: path.relative(repoRoot, result.repositoryRoot),
  closure: path.relative(repoRoot, result.closurePath),
  version,
  channel,
  fingerprint: result.closure.signing.fingerprint,
  packageSetRootSha256: result.closure.packageSetRootSha256
}, null, 2));
