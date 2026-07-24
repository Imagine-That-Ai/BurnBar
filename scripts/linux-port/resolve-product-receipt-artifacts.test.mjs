import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  ENVIRONMENTS,
  REQUIREMENTS,
  expectedArtifactNames,
  main,
  selectReceiptArtifacts,
  validateReceiptProducerRun
} from './resolve-product-receipt-artifacts.mjs';

const HEAD = 'a'.repeat(40);
const CANDIDATE_RUN_ID = '54321';
const REPOSITORY_ID = 12345;
const WORKFLOW_ID = 98765;

function artifacts() {
  return expectedArtifactNames(HEAD, CANDIDATE_RUN_ID).map((name, index) => ({
    id: 10_000 + index,
    name,
    expired: false,
    expires_at: '2099-01-01T00:00:00Z',
    size_in_bytes: 1024,
    digest: `sha256:${String(index).padStart(64, '0')}`,
    workflow_run: {
      id: 20_000 + index,
      head_sha: HEAD,
      repository_id: REPOSITORY_ID,
      head_repository_id: REPOSITORY_ID
    }
  }));
}

function run(id) {
  return {
    id,
    repository: { id: REPOSITORY_ID, full_name: 'Imagine-That-Ai/BurnBar' },
    head_repository: { id: REPOSITORY_ID, full_name: 'Imagine-That-Ai/BurnBar' },
    workflow_id: WORKFLOW_ID,
    path: '.github/workflows/linux-product-parity.yml',
    status: 'completed',
    conclusion: 'success',
    run_attempt: 1,
    head_sha: HEAD,
    event: 'workflow_dispatch'
  };
}

test('canonical receipt artifact set is exactly 40 requirements by seven environments', () => {
  const names = expectedArtifactNames(HEAD, CANDIDATE_RUN_ID);
  assert.equal(names.length, REQUIREMENTS.length * ENVIRONMENTS.length);
  assert.equal(new Set(names).size, 280);
  assert.equal(selectReceiptArtifacts(artifacts(), HEAD, CANDIDATE_RUN_ID).length, 280);
});

test('missing, stale, empty, and cross-HEAD artifacts fail closed', () => {
  const mutations = [
    (rows) => { rows.pop(); },
    (rows) => { rows[0].expired = true; },
    (rows) => { rows[0].size_in_bytes = 0; },
    (rows) => { rows[0].workflow_run.head_sha = 'b'.repeat(40); }
  ];
  for (const mutate of mutations) {
    const rows = artifacts();
    mutate(rows);
    assert.throws(() => selectReceiptArtifacts(rows, HEAD, CANDIDATE_RUN_ID));
  }
});

test('successful same-candidate recertification deterministically selects the newest immutable artifact', () => {
  const rows = artifacts();
  rows.push({ ...structuredClone(rows[0]), id: 999_999, digest: `sha256:${'f'.repeat(64)}` });
  const selected = selectReceiptArtifacts(rows, HEAD, CANDIDATE_RUN_ID);
  assert.equal(selected.length, 280);
  assert.equal(selected[0].artifact.id, 999_999);
});

test('producer workflow, repository, attempt, conclusion, source, and artifact binding fail independently', () => {
  const artifact = artifacts()[0];
  const base = { artifact, workflowRunId: artifact.workflow_run.id, targetHead: HEAD, workflowId: WORKFLOW_ID };
  const mutations = [
    (value) => { value.repository.full_name = 'attacker/repo'; },
    (value) => { value.workflow_id += 1; },
    (value) => { value.path = '.github/workflows/other.yml'; },
    (value) => { value.run_attempt = 2; },
    (value) => { value.conclusion = 'failure'; },
    (value) => { value.head_sha = 'b'.repeat(40); },
    (value) => { value.event = 'pull_request'; },
    (value) => { value.id += 1; }
  ];
  for (const mutate of mutations) {
    const value = run(artifact.workflow_run.id);
    mutate(value);
    assert.throws(() => validateReceiptProducerRun(value, base));
  }
});

test('resolver emits all immutable artifact ids only after validating every producer run', () => {
  const rows = artifacts();
  const byRun = new Map(rows.map((artifact) => [artifact.workflow_run.id, run(artifact.workflow_run.id)]));
  const api = (kind, value) => kind === 'workflow'
    ? { id: WORKFLOW_ID, path: '.github/workflows/linux-product-parity.yml', state: 'active' }
    : kind === 'artifacts' ? rows : byRun.get(value);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-receipt-artifacts-'));
  const output = path.join(directory, 'github-output');
  const result = main([
    '--target-head', HEAD,
    '--candidate-run-id', CANDIDATE_RUN_ID
  ], api, output);
  assert.equal(result.count, 280);
  assert.equal(result.artifactIds.length, 280);
  assert.match(fs.readFileSync(output, 'utf8'), /artifact_count=280/u);
  fs.rmSync(directory, { recursive: true, force: true });
});
