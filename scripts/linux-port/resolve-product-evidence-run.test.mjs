import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  EVIDENCE_POLICY,
  main,
  parseArguments,
  validateArtifactResponse,
  validateRun
} from './resolve-product-evidence-run.mjs';

const RUN_ID = '28994097882';
const HEAD = 'a'.repeat(40);
const REPOSITORY_ID = 12345;

function validRun() {
  return {
    id: Number(RUN_ID),
    repository: { id: REPOSITORY_ID, full_name: EVIDENCE_POLICY.repository },
    head_repository: { id: REPOSITORY_ID, full_name: EVIDENCE_POLICY.repository },
    workflow_id: EVIDENCE_POLICY.workflowId,
    path: EVIDENCE_POLICY.workflowPath,
    status: 'completed',
    conclusion: 'success',
    head_sha: HEAD,
    event: 'workflow_dispatch',
    run_attempt: 1
  };
}

function validArtifacts() {
  return {
    total_count: 1,
    artifacts: [{
      id: 8189285431,
      name: EVIDENCE_POLICY.artifactName,
      expired: false,
      expires_at: '2099-01-01T00:00:00Z',
      size_in_bytes: 1024,
      digest: `sha256:${'b'.repeat(64)}`,
      workflow_run: {
        id: Number(RUN_ID),
        head_sha: HEAD,
        repository_id: REPOSITORY_ID,
        head_repository_id: REPOSITORY_ID
      }
    }]
  };
}

test('canonical trusted run and immutable artifact resolve to GitHub outputs', () => {
  const output = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'product-evidence-run-')), 'output');
  const calls = [];
  const api = (endpoint) => {
    calls.push(endpoint);
    return calls.length === 1 ? validRun() : validArtifacts();
  };
  const result = main(['--run-id', RUN_ID, '--target-head', HEAD], api, output);
  assert.deepEqual(result, { artifactId: '8189285431', artifactDigest: `sha256:${'b'.repeat(64)}` });
  assert.match(fs.readFileSync(output, 'utf8'), /artifact_id=8189285431\nartifact_digest=sha256:/u);
  assert.deepEqual(calls, [
    `repos/${EVIDENCE_POLICY.repository}/actions/runs/${RUN_ID}`,
    `repos/${EVIDENCE_POLICY.repository}/actions/runs/${RUN_ID}/artifacts?name=${EVIDENCE_POLICY.artifactName}&per_page=100`
  ]);
  fs.rmSync(path.dirname(output), { recursive: true, force: true });
});

test('argument parser rejects malformed, missing, duplicate, and unknown inputs', () => {
  for (const argv of [
    [],
    ['--run-id', '0', '--target-head', HEAD],
    ['--run-id', '01', '--target-head', HEAD],
    ['--run-id', RUN_ID, '--target-head', 'A'.repeat(40)],
    ['--run-id', RUN_ID, '--run-id', RUN_ID, '--target-head', HEAD],
    ['--artifact', 'anything', '--target-head', HEAD]
  ]) assert.throws(() => parseArguments(argv));
});

test('workflow run identity, state, source, event, and attempt fail closed independently', () => {
  const mutations = [
    (run) => { run.id += 1; },
    (run) => { run.repository.full_name = 'attacker/repo'; },
    (run) => { run.head_repository.id += 1; },
    (run) => { run.workflow_id += 1; },
    (run) => { run.path = '.github/workflows/other.yml'; },
    (run) => { run.status = 'in_progress'; },
    (run) => { run.conclusion = 'failure'; },
    (run) => { run.head_sha = 'c'.repeat(40); },
    (run) => { run.event = 'pull_request'; },
    (run) => { run.run_attempt = 2; }
  ];
  for (const mutate of mutations) {
    const run = validRun();
    mutate(run);
    assert.throws(() => validateRun(run, { runId: RUN_ID, targetHead: HEAD }));
  }
});

test('artifact exact cardinality, liveness, digest, and workflow binding fail closed', () => {
  const context = { runId: RUN_ID, targetHead: HEAD, repositoryId: REPOSITORY_ID };
  const mutations = [
    (response) => { response.total_count = 0; response.artifacts = []; },
    (response) => { response.total_count = 2; response.artifacts.push({ ...response.artifacts[0], id: 9 }); },
    (response) => { response.artifacts[0].name = 'other'; },
    (response) => { response.artifacts[0].expired = true; },
    (response) => { response.artifacts[0].expires_at = '2000-01-01T00:00:00Z'; },
    (response) => { response.artifacts[0].size_in_bytes = 0; },
    (response) => { response.artifacts[0].digest = 'sha256:bad'; },
    (response) => { response.artifacts[0].workflow_run.id += 1; },
    (response) => { response.artifacts[0].workflow_run.head_sha = 'c'.repeat(40); },
    (response) => { response.artifacts[0].workflow_run.repository_id += 1; },
    (response) => { response.artifacts[0].workflow_run.head_repository_id += 1; }
  ];
  for (const mutate of mutations) {
    const response = validArtifacts();
    mutate(response);
    assert.throws(() => validateArtifactResponse(response, context));
  }
});
