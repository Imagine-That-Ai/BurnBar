import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { assertInstalledManifest } from './linux-installed-manifest.mjs';

export function readShardAttestationSubject(shardRoot, record, label) {
  if (record === null || typeof record !== 'object' || Array.isArray(record)
      || typeof (record.file ?? record.path) !== 'string'
      || !/^[a-f0-9]{64}$/u.test(record.sha256 ?? '')
      || !Number.isSafeInteger(record.size) || record.size < 0) {
    throw new Error(`${label} record is missing or invalid`);
  }
  const root = fs.realpathSync(shardRoot);
  const source = path.resolve(root, record.file ?? record.path);
  const relative = path.relative(root, source);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes its architecture shard`);
  }
  let current = root;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
  const descriptor = fs.openSync(source, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
  try {
    const before = fs.fstatSync(descriptor);
    if (!before.isFile() || before.size !== record.size) throw new Error(`${label} is not the recorded regular file`);
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
      throw new Error(`${label} changed while it was read`);
    }
    const digest = crypto.createHash('sha256').update(bytes).digest('hex');
    if (digest !== record.sha256) throw new Error(`${label} SHA-256 does not match the shard record`);
    return { bytes, sha256: digest, size: bytes.length };
  } finally {
    fs.closeSync(descriptor);
  }
}

export function validateAggregateInstalledManifest(bytes, expected) {
  let manifest;
  try {
    manifest = JSON.parse(bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`installed manifest is not valid JSON: ${error.message}`);
  }
  assertInstalledManifest(manifest);
  if (manifest.packageArchitecture !== expected.architecture
      || manifest.packageFormat !== expected.format
      || manifest.packageVersion !== expected.version
      || manifest.gitCommit !== expected.commit) {
    throw new Error('installed manifest identity does not match its aggregate package row');
  }
  return manifest;
}
