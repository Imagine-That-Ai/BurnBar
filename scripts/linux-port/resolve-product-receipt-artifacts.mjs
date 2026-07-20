#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const RECEIPT_ARTIFACT_POLICY = Object.freeze({
  repository: 'Imagine-That-Ai/BurnBar',
  workflowPath: '.github/workflows/linux-product-parity.yml',
  allowedEvents: Object.freeze(['workflow_dispatch'])
});
export const REQUIREMENTS = Object.freeze(Array.from(
  { length: 40 },
  (_, index) => `P-${String(index + 1).padStart(2, '0')}`
));
export const ENVIRONMENTS = Object.freeze([
  'ubuntu-24.04-gnome-x11-x86_64',
  'ubuntu-24.04-gnome-x11-aarch64',
  'ubuntu-24.04-gnome-wayland-x86_64',
  'ubuntu-24.04-gnome-wayland-aarch64',
  'fedora-kde-wayland-x86_64',
  'fedora-kde-wayland-aarch64',
  'arch-sway-wayland-x86_64'
]);

const SHA = /^[a-f0-9]{40}$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;

export function expectedArtifactNames(targetHead, candidateRunId) {
  if (!SHA.test(targetHead)) throw new Error('target HEAD must be a lowercase 40-character commit');
  if (!/^[1-9][0-9]*$/u.test(String(candidateRunId ?? ''))) throw new Error('candidate run id must be canonical');
  return REQUIREMENTS.flatMap((requirement) =>
    ENVIRONMENTS.map((environment) =>
      `linux-product-parity-${targetHead}-${candidateRunId}-${requirement}-${environment}`
    )
  );
}

function requiredObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`);
  return value;
}

export function selectReceiptArtifacts(artifacts, targetHead, candidateRunId, now = new Date()) {
  if (!Array.isArray(artifacts)) throw new Error('artifact catalog must be an array');
  const expected = expectedArtifactNames(targetHead, candidateRunId);
  const expectedSet = new Set(expected);
  const byName = new Map();
  for (const artifact of artifacts) {
    if (!expectedSet.has(artifact?.name)) continue;
    const rows = byName.get(artifact.name) ?? [];
    rows.push(artifact);
    byName.set(artifact.name, rows);
  }
  const selected = [];
  for (const name of expected) {
    const matches = byName.get(name) ?? [];
    if (matches.length === 0) throw new Error(`receipt artifact is missing for ${name}`);
    const artifact = requiredObject(
      [...matches].sort((left, right) => (right?.id ?? 0) - (left?.id ?? 0))[0],
      `receipt artifact ${name}`
    );
    const workflowRun = requiredObject(artifact.workflow_run, `receipt artifact ${name} workflow_run`);
    if (!Number.isSafeInteger(artifact.id) || artifact.id <= 0 || artifact.expired !== false
        || !Number.isSafeInteger(artifact.size_in_bytes) || artifact.size_in_bytes <= 0
        || !DIGEST.test(artifact.digest ?? '')) {
      throw new Error(`receipt artifact is empty, expired, or malformed: ${name}`);
    }
    const expiresAt = new Date(artifact.expires_at);
    if (!Number.isFinite(expiresAt.getTime()) || expiresAt <= now) throw new Error(`receipt artifact expiry is invalid: ${name}`);
    if (!Number.isSafeInteger(workflowRun.id) || workflowRun.id <= 0 || workflowRun.head_sha !== targetHead) {
      throw new Error(`receipt artifact is not bound to the target HEAD: ${name}`);
    }
    selected.push({ artifact, workflowRunId: workflowRun.id });
  }
  return selected;
}

export function validateReceiptProducerRun(run, context) {
  requiredObject(run, 'receipt producer run');
  const repository = requiredObject(run.repository, 'receipt producer repository');
  const headRepository = requiredObject(run.head_repository, 'receipt producer head_repository');
  if (run.id !== context.workflowRunId || repository.full_name !== RECEIPT_ARTIFACT_POLICY.repository
      || headRepository.full_name !== RECEIPT_ARTIFACT_POLICY.repository
      || !Number.isSafeInteger(repository.id) || repository.id !== headRepository.id) {
    throw new Error('receipt producer repository or run identity is not trusted');
  }
  if (run.workflow_id !== context.workflowId || run.path !== RECEIPT_ARTIFACT_POLICY.workflowPath) {
    throw new Error('receipt producer workflow identity is not trusted');
  }
  if (run.status !== 'completed' || run.conclusion !== 'success' || run.run_attempt !== 1) {
    throw new Error('receipt producer run must be first-attempt successful');
  }
  if (run.head_sha !== context.targetHead || !RECEIPT_ARTIFACT_POLICY.allowedEvents.includes(run.event)) {
    throw new Error('receipt producer run source is not trusted');
  }
  const artifactRun = context.artifact.workflow_run;
  if (artifactRun.id !== run.id || artifactRun.head_sha !== run.head_sha
      || artifactRun.repository_id !== repository.id || artifactRun.head_repository_id !== repository.id) {
    throw new Error('receipt artifact workflow binding does not match its producer run');
  }
}

function ghJson(args) {
  const result = spawnSync('gh', ['api', ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (result.error?.code === 'ENOENT') throw new Error('gh is required to resolve product receipt artifacts');
  if (result.status !== 0) throw new Error(`gh api failed: ${(result.stderr || result.stdout || 'unknown error').trim()}`);
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`gh api returned invalid JSON: ${error.message}`);
  }
}

function defaultApi(kind, value = null) {
  if (kind === 'workflow') {
    return ghJson([`repos/${RECEIPT_ARTIFACT_POLICY.repository}/actions/workflows/linux-product-parity.yml`]);
  }
  if (kind === 'artifacts') {
    const pages = ghJson(['--paginate', '--slurp', `repos/${RECEIPT_ARTIFACT_POLICY.repository}/actions/artifacts?per_page=100`]);
    return pages.flatMap((page) => page.artifacts ?? []);
  }
  return ghJson([`repos/${RECEIPT_ARTIFACT_POLICY.repository}/actions/runs/${value}`]);
}

export function resolveProductReceiptArtifacts({ targetHead, candidateRunId }, api = defaultApi) {
  const workflow = requiredObject(api('workflow'), 'product parity workflow');
  if (!Number.isSafeInteger(workflow.id) || workflow.id <= 0
      || workflow.path !== RECEIPT_ARTIFACT_POLICY.workflowPath || workflow.state !== 'active') {
    throw new Error('product parity workflow identity is missing or inactive');
  }
  const selected = selectReceiptArtifacts(api('artifacts'), targetHead, candidateRunId);
  for (const context of selected) {
    validateReceiptProducerRun(api('run', context.workflowRunId), {
      ...context,
      targetHead,
      workflowId: workflow.id
    });
  }
  return {
    artifactIds: selected.map(({ artifact }) => String(artifact.id)),
    count: selected.length
  };
}

function parseArguments(argv) {
  if (argv.length !== 4) {
    throw new Error('usage: resolve-product-receipt-artifacts.mjs --target-head <commit> --candidate-run-id <id>');
  }
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) values.set(argv[index], argv[index + 1]);
  const targetHead = values.get('--target-head');
  const candidateRunId = values.get('--candidate-run-id');
  if (values.size !== 2 || !SHA.test(targetHead ?? '') || !/^[1-9][0-9]*$/u.test(candidateRunId ?? '')) {
    throw new Error('usage: resolve-product-receipt-artifacts.mjs --target-head <commit> --candidate-run-id <id>');
  }
  return { targetHead, candidateRunId };
}

function appendOutput(file, key, value) {
  fs.appendFileSync(file, `${key}=${value}\n`, { encoding: 'utf8', mode: 0o600 });
}

export function main(argv = process.argv.slice(2), api = defaultApi, output = process.env.GITHUB_OUTPUT) {
  const result = resolveProductReceiptArtifacts(parseArguments(argv), api);
  if (!output) throw new Error('GITHUB_OUTPUT is required');
  appendOutput(output, 'artifact_ids', result.artifactIds.join(','));
  appendOutput(output, 'artifact_count', String(result.count));
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`product receipt artifact resolution failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
