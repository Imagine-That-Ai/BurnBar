import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  LINUX_WORKFLOW_WIRING_COMPOSITE_SOURCE_PATHS,
  LINUX_WORKFLOW_WIRING_SOURCE_PATHS,
  loadLinuxWorkflowWiringInput,
  verifyLinuxWorkflowWiring
} from '../verify-linux-workflow-wiring.mjs';
import { readRegularSnapshot } from './product-proof-closure.mjs';

export const P38_WORKFLOW_PROOF_FILENAME = 'p38-release-automation-verification.json';
export const P38_MUTATION_TEST_PATH = 'scripts/linux-port/verify-linux-workflow-wiring.test.mjs';
export const P38_MUTATION_TEST_COMMAND = `node --test ${P38_MUTATION_TEST_PATH}`;

const HEAD = /^[a-f0-9]{40}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const CANDIDATE_DIGEST = /^sha256:[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const ENVIRONMENT = /^(ubuntu-24\.04-gnome-(?:x11|wayland)-(?:x86_64|aarch64)|fedora-kde-wayland-(?:x86_64|aarch64)|arch-sway-wayland-x86_64)$/u;

export const P38_WORKFLOW_SOURCE_PATHS = Object.freeze([
  ...Object.values(LINUX_WORKFLOW_WIRING_SOURCE_PATHS),
  ...Object.values(LINUX_WORKFLOW_WIRING_COMPOSITE_SOURCE_PATHS).flat(),
  'scripts/linux-port/verify-linux-workflow-wiring.mjs',
  P38_MUTATION_TEST_PATH
].sort());

function exactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(`${label} fields are not exact`);
  }
}

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

export function captureP38SourceRecords(repoRoot) {
  return P38_WORKFLOW_SOURCE_PATHS.map((sourcePath) => {
    const snapshot = readRegularSnapshot(repoRoot, sourcePath, `P-38 workflow source ${sourcePath}`);
    return { path: sourcePath, sha256: snapshot.sha256, size: snapshot.size };
  });
}

export function mutationSuiteSummary({ exitCode, stdout, stderr }) {
  const combined = `${stdout ?? ''}\n${stderr ?? ''}`;
  const number = (label) => {
    const match = combined.match(new RegExp(`^# ${label} (\\d+)$`, 'mu'));
    return match ? Number(match[1]) : null;
  };
  return {
    command: P38_MUTATION_TEST_COMMAND,
    testPath: P38_MUTATION_TEST_PATH,
    exitCode,
    testCount: number('tests'),
    passCount: number('pass'),
    failCount: number('fail'),
    outputSha256: sha256(Buffer.from(combined, 'utf8')),
    passed: exitCode === 0 && number('tests') > 0 && number('tests') === number('pass') && number('fail') === 0
  };
}

export function validateP38ReleaseAutomationProof({
  repoRoot,
  snapshot,
  targetHead,
  environmentId,
  candidateRunId,
  candidateArtifactDigest
}) {
  const document = parseJson(snapshot, 'P-38 release automation proof');
  exactKeys(document, [
    'candidate', 'environmentId', 'generatedAt', 'id', 'mutationSuite', 'requirementId',
    'schemaVersion', 'sources', 'status', 'targetHead', 'workflowVerification'
  ], 'P-38 release automation proof');
  exactKeys(document.candidate, ['artifactDigest', 'runId'], 'P-38 candidate binding');
  exactKeys(document.workflowVerification, ['failures', 'passed'], 'P-38 workflow verification');
  exactKeys(document.mutationSuite, [
    'command', 'exitCode', 'failCount', 'outputSha256', 'passCount', 'passed', 'testCount', 'testPath'
  ], 'P-38 mutation suite');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p38-release-automation-proof-v1'
      || document.requirementId !== 'P-38' || document.status !== 'passed'
      || document.targetHead !== targetHead || !HEAD.test(document.targetHead ?? '')
      || document.environmentId !== environmentId || !ENVIRONMENT.test(document.environmentId ?? '')
      || document.candidate.runId !== String(candidateRunId) || !RUN_ID.test(document.candidate.runId ?? '')
      || document.candidate.artifactDigest !== candidateArtifactDigest
      || !CANDIDATE_DIGEST.test(document.candidate.artifactDigest ?? '')
      || !Number.isFinite(Date.parse(document.generatedAt ?? ''))) {
    throw new Error('P-38 release automation proof is not invocation- and candidate-bound');
  }
  if (document.workflowVerification.passed !== true
      || !Array.isArray(document.workflowVerification.failures)
      || document.workflowVerification.failures.length !== 0) {
    throw new Error('P-38 workflow verification did not pass');
  }
  const suite = document.mutationSuite;
  if (suite.command !== P38_MUTATION_TEST_COMMAND || suite.testPath !== P38_MUTATION_TEST_PATH
      || suite.exitCode !== 0 || suite.passed !== true || !Number.isSafeInteger(suite.testCount)
      || suite.testCount <= 0 || suite.passCount !== suite.testCount || suite.failCount !== 0
      || !SHA256.test(suite.outputSha256 ?? '')) {
    throw new Error('P-38 workflow mutation suite did not pass completely');
  }
  if (!Array.isArray(document.sources) || document.sources.length !== P38_WORKFLOW_SOURCE_PATHS.length) {
    throw new Error('P-38 workflow proof does not contain the exact source set');
  }
  const sourcePaths = document.sources.map((source) => source?.path);
  if (new Set(sourcePaths).size !== P38_WORKFLOW_SOURCE_PATHS.length
      || P38_WORKFLOW_SOURCE_PATHS.some((sourcePath, index) => sourcePaths[index] !== sourcePath)) {
    throw new Error('P-38 workflow proof source paths are not exact and sorted');
  }
  for (const source of document.sources) {
    exactKeys(source, ['path', 'sha256', 'size'], `P-38 workflow source ${source?.path ?? '<missing>'}`);
    const current = readRegularSnapshot(repoRoot, source.path, `P-38 workflow source ${source.path}`);
    if (source.sha256 !== current.sha256 || source.size !== current.size || !SHA256.test(source.sha256 ?? '')) {
      throw new Error(`P-38 workflow source is stale or substituted: ${source.path}`);
    }
  }
  const independentlyVerified = verifyLinuxWorkflowWiring(loadLinuxWorkflowWiringInput(repoRoot));
  if (!independentlyVerified.passed || independentlyVerified.failures.length !== 0) {
    throw new Error(`P-38 workflow wiring fails independent verification: ${independentlyVerified.failures.join('; ')}`);
  }
  return document;
}

export function canonicalP38ProofPath(inputRoot) {
  return path.join(inputRoot, P38_WORKFLOW_PROOF_FILENAME);
}

export function removeStaleP38Proof(inputRoot) {
  fs.rmSync(canonicalP38ProofPath(inputRoot), { force: true });
}
