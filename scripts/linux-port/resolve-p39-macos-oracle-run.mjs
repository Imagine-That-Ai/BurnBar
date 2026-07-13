#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const P39_MACOS_ORACLE_POLICY = Object.freeze({
  repository: 'Imagine-That-Ai/BurnBar',
  workflowPath: '.github/workflows/linux-p39-macos-oracle.yml',
  artifactName: 'linux-p39-macos-oracle',
  allowedEvents: Object.freeze(['push', 'workflow_dispatch', 'workflow_call'])
});

const SHA_PATTERN = /^[a-f0-9]{40}$/u;
const RUN_ID_PATTERN = /^[1-9][0-9]*$/u;
const DIGEST_PATTERN = /^sha256:[a-f0-9]{64}$/u;

function requiredObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

export function parseArguments(argv) {
  const expected = new Set(['--run-id', '--target-head']);
  const parsed = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!expected.has(flag)) throw new Error(`unknown argument: ${flag}`);
    if (parsed.has(flag)) throw new Error(`${flag} may be specified only once`);
    if (value === undefined || value.startsWith('--')) throw new Error(`${flag} requires a value`);
    parsed.set(flag, value);
  }
  for (const flag of expected) if (!parsed.has(flag)) throw new Error(`${flag} is required`);
  const runId = parsed.get('--run-id');
  const targetHead = parsed.get('--target-head');
  if (!RUN_ID_PATTERN.test(runId) || !Number.isSafeInteger(Number(runId))) {
    throw new Error('--run-id must be a positive canonical safe integer');
  }
  if (!SHA_PATTERN.test(targetHead)) throw new Error('--target-head must be a lowercase 40-character commit');
  return { runId, targetHead };
}

export function validateRun(run, { runId, targetHead }, policy = P39_MACOS_ORACLE_POLICY) {
  requiredObject(run, 'workflow run');
  const repository = requiredObject(run.repository, 'workflow run repository');
  const headRepository = requiredObject(run.head_repository, 'workflow run head_repository');
  if (String(run.id) !== runId) throw new Error('workflow run id does not match the requested run');
  if (repository.full_name !== policy.repository || headRepository.full_name !== policy.repository
      || !Number.isSafeInteger(repository.id) || repository.id !== headRepository.id) {
    throw new Error('workflow run repository identity is not trusted');
  }
  if (run.path !== policy.workflowPath) throw new Error('workflow run producer identity is not trusted');
  if (run.status !== 'completed' || run.conclusion !== 'success') {
    throw new Error('workflow run must be completed successfully');
  }
  if (run.head_sha !== targetHead) throw new Error('workflow run head_sha does not match the target commit');
  if (!policy.allowedEvents.includes(run.event)) throw new Error('workflow run event is not allowed');
  if (run.run_attempt !== 1) throw new Error('workflow reruns are not accepted as oracle producers');
  return { repositoryId: repository.id };
}

export function validateArtifactResponse(response, context, policy = P39_MACOS_ORACLE_POLICY, now = new Date()) {
  requiredObject(response, 'artifact response');
  if (response.total_count !== 1 || !Array.isArray(response.artifacts) || response.artifacts.length !== 1) {
    throw new Error('oracle run must contain exactly one canonical macOS oracle artifact');
  }
  const artifact = requiredObject(response.artifacts[0], 'macOS oracle artifact');
  const workflowRun = requiredObject(artifact.workflow_run, 'macOS oracle artifact workflow_run');
  if (!Number.isSafeInteger(artifact.id) || artifact.id <= 0 || artifact.name !== policy.artifactName) {
    throw new Error('macOS oracle artifact identity is invalid');
  }
  if (artifact.expired !== false || !Number.isSafeInteger(artifact.size_in_bytes) || artifact.size_in_bytes <= 0) {
    throw new Error('macOS oracle artifact is expired or empty');
  }
  if (!DIGEST_PATTERN.test(artifact.digest ?? '')) throw new Error('macOS oracle artifact digest is invalid');
  const expiresAt = new Date(artifact.expires_at);
  if (!Number.isFinite(expiresAt.getTime()) || expiresAt <= now) {
    throw new Error('macOS oracle artifact expiry is invalid or elapsed');
  }
  if (String(workflowRun.id) !== context.runId || workflowRun.head_sha !== context.targetHead
      || workflowRun.repository_id !== context.repositoryId
      || workflowRun.head_repository_id !== context.repositoryId) {
    throw new Error('macOS oracle artifact is not bound to the trusted workflow run');
  }
  return { artifactId: String(artifact.id), artifactDigest: artifact.digest };
}

function ghApi(endpoint) {
  const result = spawnSync('gh', ['api', endpoint], { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (result.error?.code === 'ENOENT') throw new Error('gh is required to resolve macOS oracle provenance');
  if (result.status !== 0) throw new Error(`gh api failed: ${(result.stderr || result.stdout || 'unknown error').trim()}`);
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`gh api returned invalid JSON: ${error.message}`);
  }
}

function appendOutput(file, name, value) {
  fs.appendFileSync(file, `${name}=${value}\n`, { encoding: 'utf8', mode: 0o600 });
}

export function resolveP39MacOSOracleRun(options, api = ghApi) {
  const run = api(`repos/${P39_MACOS_ORACLE_POLICY.repository}/actions/runs/${options.runId}`);
  const { repositoryId } = validateRun(run, options);
  const artifacts = api(
    `repos/${P39_MACOS_ORACLE_POLICY.repository}/actions/runs/${options.runId}/artifacts?name=${P39_MACOS_ORACLE_POLICY.artifactName}&per_page=100`
  );
  return { runId: options.runId, ...validateArtifactResponse(artifacts, { ...options, repositoryId }) };
}

export function main(argv = process.argv.slice(2), api = ghApi, outputFile = process.env.GITHUB_OUTPUT) {
  const options = parseArguments(argv);
  const result = resolveP39MacOSOracleRun(options, api);
  if (!outputFile) throw new Error('GITHUB_OUTPUT is required');
  appendOutput(outputFile, 'run_id', result.runId);
  appendOutput(outputFile, 'artifact_id', result.artifactId);
  appendOutput(outputFile, 'artifact_digest', result.artifactDigest);
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`P-39 macOS oracle resolution failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
