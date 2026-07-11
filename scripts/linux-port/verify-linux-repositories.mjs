#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyLinuxRepositories } from './lib/linux-repository.mjs';

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

const result = verifyLinuxRepositories({ repoRoot, releaseOut, configPath, version, channel });
console.log(JSON.stringify({
  schemaVersion: 1,
  version,
  channel,
  passed: result.passed,
  failures: result.failures
}, null, 2));
process.exit(result.passed ? 0 : 1);
