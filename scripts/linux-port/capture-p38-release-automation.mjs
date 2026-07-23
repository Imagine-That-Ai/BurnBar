#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { atomicWriteJson, readRegularSnapshot } from './lib/product-proof-closure.mjs';
import {
  canonicalP38ProofPath,
  captureP38SourceRecords,
  mutationSuiteSummary,
  removeStaleP38Proof,
  validateP38ReleaseAutomationProof
} from './lib/p38-release-automation-proof.mjs';
import { loadLinuxWorkflowWiringInput, verifyLinuxWorkflowWiring } from './verify-linux-workflow-wiring.mjs';

const DEFAULT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function parseArgs(argv) {
  const allowed = new Set([
    '--input-root', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || values.has(flag)) throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    values.set(flag, value);
  }
  for (const flag of allowed) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return Object.fromEntries([...values].map(([key, value]) => [key.slice(2).replaceAll('-', '_'), value]));
}

export function captureP38ReleaseAutomation({
  repoRoot = DEFAULT_ROOT,
  inputRoot,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  runMutationSuite = null,
  resolveHead = null
}) {
  const repository = fs.realpathSync(repoRoot);
  const evidenceRoot = fs.realpathSync(inputRoot);
  const relative = path.relative(repository, evidenceRoot);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('P-38 input root must be inside the repository');
  }
  removeStaleP38Proof(evidenceRoot);
  const currentHead = resolveHead
    ? { status: 0, stdout: `${resolveHead()}\n` }
    : spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repository, encoding: 'utf8' });
  if (currentHead.status !== 0 || currentHead.stdout.trim() !== targetHead) {
    throw new Error('P-38 capture checkout is not the requested target HEAD');
  }
  const wiring = verifyLinuxWorkflowWiring(loadLinuxWorkflowWiringInput(repository));
  if (!wiring.passed || wiring.failures.length !== 0) {
    throw new Error(`P-38 workflow verification failed: ${wiring.failures.join('; ')}`);
  }
  const execution = runMutationSuite
    ? runMutationSuite()
    : spawnSync(process.execPath, ['--test', 'scripts/linux-port/verify-linux-workflow-wiring.test.mjs'], {
        cwd: repository,
        encoding: 'utf8',
        maxBuffer: 16 * 1024 * 1024
      });
  const mutationSuite = mutationSuiteSummary({
    exitCode: execution.status ?? execution.exitCode ?? 1,
    stdout: execution.stdout ?? '',
    stderr: execution.stderr ?? ''
  });
  if (!mutationSuite.passed) throw new Error('P-38 workflow mutation suite failed');
  const document = {
    schemaVersion: 1,
    id: 'openburnbar-linux-p38-release-automation-proof-v1',
    generatedAt: new Date().toISOString(),
    requirementId: 'P-38',
    environmentId,
    targetHead,
    candidate: { runId: String(candidateRunId), artifactDigest: candidateArtifactDigest },
    workflowVerification: wiring,
    mutationSuite,
    sources: captureP38SourceRecords(repository),
    status: 'passed'
  };
  const output = canonicalP38ProofPath(evidenceRoot);
  atomicWriteJson(output, document);
  validateP38ReleaseAutomationProof({
    repoRoot: repository,
    snapshot: readRegularSnapshot(repository, path.relative(repository, output), 'P-38 release automation proof'),
    targetHead,
    environmentId,
    candidateRunId,
    candidateArtifactDigest
  });
  return { output, document };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const result = captureP38ReleaseAutomation({
    inputRoot: path.resolve(args.input_root),
    environmentId: args.environment,
    targetHead: args.target_head,
    candidateRunId: args.candidate_run_id,
    candidateArtifactDigest: args.candidate_artifact_digest
  });
  console.log(JSON.stringify({ output: path.relative(DEFAULT_ROOT, result.output), status: result.document.status }, null, 2));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`P-38 release automation capture failed: ${error.message}\n`);
    process.exit(1);
  }
}
