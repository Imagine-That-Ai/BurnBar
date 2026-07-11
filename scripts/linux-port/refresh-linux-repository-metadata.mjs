#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { refreshLinuxRepositoryMetadata } from './lib/linux-repository.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--private-key-stdin') { values.privateKeyStdin = true; continue; }
    if (!argument.startsWith('--')) throw new Error(`unexpected argument: ${argument}`);
    const next = argv[++index];
    if (!next || next.startsWith('--')) throw new Error(`missing value for ${argument}`);
    values[argument.slice(2).replaceAll('-', '_')] = next;
  }
  return values;
}

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    fs.linkSync(temporary, file);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (Object.hasOwn(process.env, 'OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY')) {
    throw new Error('repository GPG private key environment variables are forbidden; pass the key by stdin or a protected file');
  }
  const privateKeyFile = args.private_key_file;
  if (Boolean(privateKeyFile) === Boolean(args.privateKeyStdin)) {
    throw new Error('exactly one of --private-key-stdin or --private-key-file is required');
  }
  let privateKeyBytes;
  if (args.privateKeyStdin) {
    privateKeyBytes = fs.readFileSync(0);
  } else {
    const file = path.resolve(privateKeyFile);
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0) {
      throw new Error('--private-key-file must be a regular file with no group or other permissions');
    }
    privateKeyBytes = fs.readFileSync(file);
  }
  if (privateKeyBytes.length === 0 || privateKeyBytes.length > 1024 * 1024) {
    throw new Error('repository private key must be non-empty and at most 1 MiB');
  }
  const refreshEpoch = Number(args.refresh_epoch);
  const sourceRepositoryRoot = path.resolve(args.source ?? path.join(repoRoot, '.linux-refresh/source-repository'));
  const outputRepositoryRoot = path.resolve(args.output ?? path.join(repoRoot, '.linux-refresh/repositories'));
  const configPath = path.resolve(args.config ?? path.join(repoRoot, 'packaging/linux/distribution-channels.json'));
  let result;
  try {
    result = refreshLinuxRepositoryMetadata({
      repoRoot,
      sourceRepositoryRoot,
      outputRepositoryRoot,
      configPath,
      privateKeyBytes,
      refreshEpoch
    });
  } finally {
    privateKeyBytes.fill(0);
  }
  const receipt = {
    schemaVersion: 1,
    operation: 'refresh-linux-repository-metadata',
    passed: true,
    generatedAt: new Date().toISOString(),
    channel: result.closure.channel,
    version: result.closure.version,
    sourceCommit: result.closure.gitCommit,
    packageSetRootSha256: result.closure.packageSetRootSha256,
    parentSnapshotId: result.parentSnapshotId,
    snapshotId: result.snapshotId,
    releaseDate: result.closure.repositories.apt.releaseDate,
    validUntil: result.closure.repositories.apt.validUntil,
    signingFingerprint: result.closure.signing.signingFingerprint,
    allowedChangedFiles: result.allowedChangedFiles,
    packages: result.closure.packages.map((row) => ({
      type: row.type,
      architecture: row.architecture,
      file: row.repository.file,
      sha256: row.repository.sha256,
      size: row.repository.size
    }))
  };
  if (args.receipt) atomicJson(path.resolve(args.receipt), receipt);
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
