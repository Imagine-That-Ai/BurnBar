import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { captureP38ReleaseAutomation } from './capture-p38-release-automation.mjs';
import {
  P38_WORKFLOW_PROOF_FILENAME,
  P38_WORKFLOW_SOURCE_PATHS
} from './lib/p38-release-automation-proof.mjs';

const HEAD = 'a'.repeat(40);
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-x86_64';
const CANDIDATE_RUN_ID = '12345';
const CANDIDATE_ARTIFACT_DIGEST = `sha256:${'e'.repeat(64)}`;

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p38-proof-'));
  for (const relative of P38_WORKFLOW_SOURCE_PATHS) {
    const destination = path.join(root, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.resolve(relative), destination);
  }
  const inputRoot = path.join(
    root,
    'docs/linux-port/evidence/product-parity-inputs/P-38',
    ENVIRONMENT
  );
  fs.mkdirSync(inputRoot, { recursive: true });
  return { root, inputRoot };
}

function passedMutationExecution() {
  return {
    status: 0,
    stdout: '# tests 18\n# pass 18\n# fail 0\n',
    stderr: ''
  };
}

function capture(subject, overrides = {}) {
  return captureP38ReleaseAutomation({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID,
    candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    runMutationSuite: passedMutationExecution,
    resolveHead: () => HEAD,
    ...overrides
  });
}

test('P-38 workflow capture is mandatory and fail closed', () => {
  const subject = fixture();
  try {
    const result = capture(subject);
    assert.equal(result.document.status, 'passed');
    assert.equal(result.document.workflowVerification.passed, true);
    assert.equal(result.document.mutationSuite.passed, true);
    assert.equal(result.document.sources.length, P38_WORKFLOW_SOURCE_PATHS.length);
    assert.equal(fs.existsSync(result.output), true);

    fs.writeFileSync(result.output, '{"status":"stale-passed"}\n');
    assert.throws(
      () => capture(subject, {
        runMutationSuite: () => ({ status: 1, stdout: '# tests 18\n# pass 17\n# fail 1\n', stderr: '' })
      }),
      /workflow mutation suite failed/u
    );
    assert.equal(fs.existsSync(path.join(subject.inputRoot, P38_WORKFLOW_PROOF_FILENAME)), false);
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('P-38 capture rejects a requested HEAD or workflow source substitution', () => {
  const subject = fixture();
  try {
    assert.throws(() => capture(subject, { resolveHead: () => 'b'.repeat(40) }), /requested target HEAD/u);
    const releaseWorkflow = path.join(subject.root, '.github/workflows/linux-release.yml');
    fs.writeFileSync(
      releaseWorkflow,
      fs.readFileSync(releaseWorkflow, 'utf8').replaceAll('finalize-product-proof-closure.mjs', 'removed-product-proof-finalizer')
    );
    assert.throws(() => capture(subject), /workflow verification failed/u);
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});
