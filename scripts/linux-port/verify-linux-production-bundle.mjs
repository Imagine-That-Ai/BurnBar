#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { repoRoot } from './lib/linux-release-common.mjs';

const dist = path.join(repoRoot, 'apps/linux-desktop/dist');
const failures = [];

if (!fs.existsSync(dist)) {
  failures.push('Linux production bundle is missing; run npm run build --prefix apps/linux-desktop first.');
} else {
  const scripts = fs.readdirSync(path.join(dist, 'assets'))
    .filter((name) => name.endsWith('.js'))
    .map((name) => fs.readFileSync(path.join(dist, 'assets', name), 'utf8'))
    .join('\n');
  for (const marker of [
    'Enable daemon fixture',
    'openburnbar.linux.daemonFixture',
    'fixture-0.1.0',
    'http://127.0.0.1',
    'ws://127.0.0.1',
    'gatewayAuthToken',
    'bearerToken'
  ]) {
    if (scripts.includes(marker)) failures.push(`production bundle contains forbidden marker: ${marker}`);
  }
}

const result = { passed: failures.length === 0, failures };
console.log(JSON.stringify(result, null, 2));
process.exit(result.passed ? 0 : 1);
