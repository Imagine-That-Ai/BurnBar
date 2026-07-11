#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const workflow = fs.readFileSync(path.join(repoRoot, '.github/workflows/linux-release.yml'), 'utf8');
const buildScript = fs.readFileSync(path.join(repoRoot, 'scripts/linux-port/build-linux-release.mjs'), 'utf8');

const forbiddenWorkflowEnv = [
  '-e ACTIONS_ID_TOKEN_REQUEST_TOKEN',
  '-e ACTIONS_ID_TOKEN_REQUEST_URL'
];
const leakedWorkflowEnv = forbiddenWorkflowEnv.filter((needle) => workflow.includes(needle));
if (leakedWorkflowEnv.length > 0) {
  console.error(`Linux release build container must not receive GitHub OIDC request credentials: ${leakedWorkflowEnv.join(', ')}`);
  process.exit(1);
}

if (!workflow.includes('-e OPENBURNBAR_CI_OIDC_AVAILABLE=true')) {
  console.error('Linux release build container should receive only the non-sensitive OIDC availability flag.');
  process.exit(1);
}

if (buildScript.includes('ACTIONS_ID_TOKEN_REQUEST_TOKEN') || buildScript.includes('ACTIONS_ID_TOKEN_REQUEST_URL')) {
  console.error('build-linux-release.mjs must not depend on raw GitHub OIDC request credential variables.');
  process.exit(1);
}

if (!buildScript.includes("process.env.OPENBURNBAR_CI_OIDC_AVAILABLE !== 'true'")) {
  console.error('build-linux-release.mjs should clear the cosign blocker from the non-sensitive OIDC availability flag.');
  process.exit(1);
}

console.log('Linux release OIDC boundary verified.');
