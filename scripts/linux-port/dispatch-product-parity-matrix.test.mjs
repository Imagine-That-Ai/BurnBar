import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  acquireStateLock,
  createGhApi,
  DISPATCH_POLICY,
  parseArguments,
  resolveTargetRef,
  runDispatcher,
  validateCanonicalMatrix,
  validateWorkflow
} from './dispatch-product-parity-matrix.mjs';
import { EVIDENCE_POLICY } from './resolve-product-evidence-run.mjs';

const REPO_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..');
const REQUIREMENTS = JSON.parse(fs.readFileSync(
  path.join(REPO_ROOT, DISPATCH_POLICY.requirementsManifest),
  'utf8'
));
const POLICIES = JSON.parse(fs.readFileSync(
  path.join(REPO_ROOT, DISPATCH_POLICY.evidencePolicies),
  'utf8'
));
const TARGET_REF = 'refs/heads/codex/linux-parity-integration-final';
const TARGET_BRANCH = 'codex/linux-parity-integration-final';
const TARGET_SHA = 'a'.repeat(40);
const CANDIDATE_RUN_ID = '28994097882';
const REPOSITORY_ID = 12345;
const WORKFLOW_ID = 998877;

function clone(value) {
  return structuredClone(value);
}

function canonicalMatrix() {
  return validateCanonicalMatrix(clone(REQUIREMENTS), clone(POLICIES));
}

function workflow() {
  return {
    id: WORKFLOW_ID,
    name: DISPATCH_POLICY.workflowName,
    path: DISPATCH_POLICY.workflowPath,
    state: 'active'
  };
}

function candidateRun() {
  return {
    id: Number(CANDIDATE_RUN_ID),
    repository: { id: REPOSITORY_ID, full_name: EVIDENCE_POLICY.repository },
    head_repository: { id: REPOSITORY_ID, full_name: EVIDENCE_POLICY.repository },
    workflow_id: EVIDENCE_POLICY.workflowId,
    path: EVIDENCE_POLICY.workflowPath,
    status: 'completed',
    conclusion: 'success',
    head_sha: TARGET_SHA,
    event: 'workflow_dispatch',
    run_attempt: 1
  };
}

function candidateArtifacts() {
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
        id: Number(CANDIDATE_RUN_ID),
        head_sha: TARGET_SHA,
        repository_id: REPOSITORY_ID,
        head_repository_id: REPOSITORY_ID
      }
    }]
  };
}

function parityRun({
  id,
  requirement,
  environment,
  status = 'completed',
  conclusion = 'success',
  attempt = 1
}) {
  return {
    id,
    run_number: id,
    created_at: `2026-07-24T12:${String(id % 60).padStart(2, '0')}:00Z`,
    repository: { id: REPOSITORY_ID, full_name: DISPATCH_POLICY.repository },
    head_repository: { id: REPOSITORY_ID, full_name: DISPATCH_POLICY.repository },
    workflow_id: WORKFLOW_ID,
    path: DISPATCH_POLICY.workflowPath,
    status,
    conclusion,
    head_sha: TARGET_SHA,
    head_branch: TARGET_BRANCH,
    event: 'workflow_dispatch',
    run_attempt: attempt,
    __pair: { requirement, environment }
  };
}

function parityArtifact(run, candidateRunId = CANDIDATE_RUN_ID) {
  return {
    id: run.id + 1_000_000,
    name: `${DISPATCH_POLICY.artifactPrefix}${TARGET_SHA}-${candidateRunId}`
      + `-${run.__pair.requirement}-${run.__pair.environment}`,
    expired: false,
    expires_at: '2099-01-01T00:00:00Z',
    size_in_bytes: 2048,
    digest: `sha256:${'c'.repeat(64)}`,
    workflow_run: {
      id: run.id,
      head_sha: TARGET_SHA,
      repository_id: REPOSITORY_ID,
      head_repository_id: REPOSITORY_ID
    }
  };
}

function baseApi({
  runs = [],
  artifacts = new Map(),
  jobs = new Map(),
  dispatch,
  emptyDispatchResponse = true,
  recordDispatch = true
} = {}) {
  const calls = [];
  const api = (endpoint, request = {}) => {
    calls.push({ endpoint, request });
    if (endpoint.endsWith(`/git/ref/heads/${TARGET_BRANCH}`)) {
      return { ref: TARGET_REF, object: { type: 'commit', sha: TARGET_SHA } };
    }
    if (endpoint.endsWith('/actions/workflows/linux-product-parity.yml')) return workflow();
    if (endpoint.endsWith(`/actions/runs/${CANDIDATE_RUN_ID}`)) return candidateRun();
    if (endpoint.includes(`/actions/runs/${CANDIDATE_RUN_ID}/artifacts?name=`)) {
      return candidateArtifacts();
    }
    if (endpoint.includes(`/actions/workflows/${WORKFLOW_ID}/runs?`)) {
      return { total_count: runs.length, workflow_runs: runs.map(({ __pair, ...run }) => run) };
    }
    const jobsMatch = /\/actions\/runs\/([0-9]+)\/jobs\?/u.exec(endpoint);
    if (jobsMatch) {
      const run = runs.find((entry) => entry.id === Number(jobsMatch[1]));
      if (jobs.has(run.id)) {
        const values = jobs.get(run.id);
        return { total_count: values.length, jobs: values };
      }
      return {
        total_count: 1,
        jobs: [{
          id: run.id + 500_000,
          name: `${run.__pair.requirement} on ${run.__pair.environment}`,
          run_id: run.id,
          run_attempt: run.run_attempt,
          head_sha: run.head_sha,
          status: run.status,
          conclusion: run.conclusion
        }]
      };
    }
    const artifactsMatch = /\/actions\/runs\/([0-9]+)\/artifacts\?/u.exec(endpoint);
    if (artifactsMatch) {
      const run = runs.find((entry) => entry.id === Number(artifactsMatch[1]));
      const values = artifacts.get(run.id)
        ?? (run.status === 'completed' && run.conclusion === 'success' ? [parityArtifact(run)] : []);
      return { total_count: values.length, artifacts: values };
    }
    if (request.method === 'POST' && endpoint.endsWith(`/actions/workflows/${WORKFLOW_ID}/dispatches`)) {
      const created = dispatch?.(request.body, calls.length) ?? {
        ...parityRun({
          id: 900_000 + calls.length,
          requirement: request.body.inputs.requirement,
          environment: request.body.inputs.environment,
          status: 'queued',
          conclusion: null
        }),
        __pair: undefined
      };
      const stored = {
        ...created,
        created_at: '2026-07-24T13:00:01Z',
        __pair: {
          requirement: request.body.inputs.requirement,
          environment: request.body.inputs.environment
        }
      };
      if (recordDispatch) runs.push(stored);
      return emptyDispatchResponse ? undefined : created;
    }
    throw new Error(`unexpected mocked endpoint: ${endpoint}`);
  };
  return { api, calls };
}

function options(update = {}) {
  return {
    targetRef: TARGET_REF,
    candidateRunId: CANDIDATE_RUN_ID,
    execute: false,
    maxConcurrency: 4,
    rateLimitMs: 0,
    pollAttempts: 2,
    pollIntervalMs: 0,
    ...update
  };
}

function dependencies(api, update = {}) {
  return {
    api,
    repoRoot: REPO_ROOT,
    requirementsManifest: clone(REQUIREMENTS),
    evidencePolicies: clone(POLICIES),
    acquireStateLock: () => () => {},
    ...update
  };
}

test('canonical manifests produce the exact deterministic 40 by 7 matrix', () => {
  const matrix = canonicalMatrix();
  assert.equal(matrix.requirements.length, 40);
  assert.equal(matrix.environments.length, 7);
  assert.equal(matrix.pairs.length, 280);
  assert.deepEqual(matrix.pairs[0], {
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-x86_64'
  });
  assert.deepEqual(matrix.pairs.at(-1), {
    requirement: 'P-40',
    environment: 'arch-sway-wayland-x86_64'
  });
});

test('manifest and evidence-policy mutations fail closed', () => {
  const mutations = [
    (requirements) => { requirements.requirements.pop(); },
    (requirements) => { requirements.requirements[0].id = 'P-40'; },
    (requirements) => { requirements.minimumSupportMatrix.pop(); },
    (requirements) => { requirements.minimumSupportMatrix[1].id = requirements.minimumSupportMatrix[0].id; },
    (requirements, policies) => {
      requirements.minimumSupportMatrix[0].id = 'attacker-linux-x86_64';
      for (const policy of policies.policies) {
        policy.requiredEnvironmentIds[0] = 'attacker-linux-x86_64';
      }
    },
    (requirements) => { requirements.policy.allRequirementsMandatory = false; },
    (_requirements, policies) => { policies.requirementsManifest = 'attacker.json'; },
    (_requirements, policies) => { policies.policies.pop(); },
    (_requirements, policies) => { policies.policies[0].requirementId = 'P-40'; },
    (_requirements, policies) => { policies.policies[0].requiredEnvironmentIds.pop(); },
    (_requirements, policies) => { policies.policies[0].registeredProducer.repository = 'attacker/repo'; },
    (_requirements, policies) => { policies.policies[0].registeredProducer.signerWorkflow = 'github.com/attacker/repo/.github/workflows/fake.yml'; }
  ];
  for (const mutate of mutations) {
    const requirements = clone(REQUIREMENTS);
    const policies = clone(POLICIES);
    mutate(requirements, policies);
    assert.throws(() => validateCanonicalMatrix(requirements, policies));
  }
});

test('arguments are dry-run by default and reject unsafe or unbounded values', () => {
  assert.deepEqual(
    parseArguments(['--ref', TARGET_REF, '--candidate-run-id', CANDIDATE_RUN_ID]),
    {
      targetRef: TARGET_REF,
      candidateRunId: CANDIDATE_RUN_ID,
      execute: false,
      maxConcurrency: DISPATCH_POLICY.defaultMaxConcurrency,
      rateLimitMs: DISPATCH_POLICY.defaultRateLimitMs,
      pollAttempts: DISPATCH_POLICY.defaultPollAttempts,
      pollIntervalMs: DISPATCH_POLICY.defaultPollIntervalMs,
      requirements: undefined,
      environments: undefined,
      stateFile: undefined
    }
  );
  const selected = parseArguments([
    '--execute',
    '--ref', TARGET_REF,
    '--candidate-run-id', CANDIDATE_RUN_ID,
    '--max-concurrency', '2',
    '--rate-ms', '250',
    '--requirements', 'P-01,P-40',
    '--environments', 'ubuntu-24.04-gnome-x11-aarch64'
  ]);
  assert.equal(selected.execute, true);
  assert.deepEqual(selected.requirements, ['P-01', 'P-40']);
  assert.deepEqual(selected.environments, ['ubuntu-24.04-gnome-x11-aarch64']);
  for (const argv of [
    [],
    ['--ref', 'main', '--candidate-run-id', CANDIDATE_RUN_ID],
    ['--ref', 'refs/heads/../main', '--candidate-run-id', CANDIDATE_RUN_ID],
    ['--ref', TARGET_REF, '--candidate-run-id', '01'],
    ['--ref', TARGET_REF, '--candidate-run-id', CANDIDATE_RUN_ID, '--execute', '--execute'],
    ['--ref', TARGET_REF, '--candidate-run-id', CANDIDATE_RUN_ID, '--max-concurrency', '0'],
    ['--ref', TARGET_REF, '--candidate-run-id', CANDIDATE_RUN_ID, '--rate-ms', '-1'],
    ['--ref', TARGET_REF, '--candidate-run-id', CANDIDATE_RUN_ID, '--requirements', 'P-01,P-01'],
    ['--ref', TARGET_REF, '--candidate-run-id', CANDIDATE_RUN_ID, '--requirements', 'P-41'],
    ['--ref', TARGET_REF, '--candidate-run-id', CANDIDATE_RUN_ID, '--environments', 'ubuntu-24.04-gnome-x11-aarch64,'],
    ['--ref', TARGET_REF, '--candidate-run-id', CANDIDATE_RUN_ID, '--environments', 'Ubuntu'],
    ['--ref', TARGET_REF, '--candidate-run-id', CANDIDATE_RUN_ID, '--unknown', 'x']
  ]) assert.throws(() => parseArguments(argv));
});

test('target ref and workflow validation reject substitution and annotated-tag cycles', () => {
  assert.deepEqual(resolveTargetRef(
    () => ({ ref: TARGET_REF, object: { type: 'commit', sha: TARGET_SHA } }),
    TARGET_REF
  ), { ref: TARGET_REF, dispatchRef: TARGET_BRANCH, sha: TARGET_SHA });

  for (const mutate of [
    (value) => { value.name = 'Other'; },
    (value) => { value.path = '.github/workflows/other.yml'; },
    (value) => { value.state = 'disabled_manually'; },
    (value) => { value.id = 0; }
  ]) {
    const value = workflow();
    mutate(value);
    assert.throws(() => validateWorkflow(value));
  }
  assert.throws(() => resolveTargetRef(
    () => ({ ref: 'refs/heads/other', object: { type: 'commit', sha: TARGET_SHA } }),
    TARGET_REF
  ));
  assert.throws(() => resolveTargetRef(
    () => ({ ref: TARGET_REF, object: { type: 'commit', sha: 'A'.repeat(40) } }),
    TARGET_REF
  ));
});

test('dry run queries status and artifacts but never dispatches', async () => {
  const successful = parityRun({
    id: 101,
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-x86_64'
  });
  const running = parityRun({
    id: 102,
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-aarch64',
    status: 'in_progress',
    conclusion: null
  });
  const failed = parityRun({
    id: 103,
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-wayland-x86_64',
    conclusion: 'failure'
  });
  const { api, calls } = baseApi({ runs: [successful, running, failed] });
  const result = await runDispatcher(options(), dependencies(api));
  assert.equal(result.mode, 'dry-run');
  assert.deepEqual(result.counts, {
    completed: 1,
    running: 1,
    queued: 0,
    failed: 1,
    missing: 277
  });
  assert.equal(result.plan.length, 278);
  assert.equal(result.plan[0].reason, 'previous-run-failed');
  assert.equal(result.execution.dispatched.length, 0);
  assert.equal(calls.some((call) => call.request.method === 'POST'), false);
});

test('canonical selectors preserve full status while planning only requested pairs', async () => {
  const successful = parityRun({
    id: 150,
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-aarch64'
  });
  const { api, calls } = baseApi({ runs: [successful] });
  const result = await runDispatcher(options({
    requirements: ['P-01', 'P-02'],
    environments: ['ubuntu-24.04-gnome-x11-aarch64']
  }), dependencies(api));
  assert.deepEqual(result.counts, {
    completed: 1,
    running: 0,
    queued: 0,
    failed: 0,
    missing: 279
  });
  assert.deepEqual(result.selection, {
    requirements: ['P-01', 'P-02'],
    environments: ['ubuntu-24.04-gnome-x11-aarch64'],
    total: 2
  });
  assert.deepEqual(result.plan, [{
    requirement: 'P-02',
    environment: 'ubuntu-24.04-gnome-x11-aarch64',
    reason: 'never-dispatched'
  }]);
  assert.equal(calls.some((call) => call.request.method === 'POST'), false);

  await assert.rejects(
    () => runDispatcher(options({ requirements: ['P-41'] }), dependencies(api)),
    /outside the canonical matrix/u
  );
  await assert.rejects(
    () => runDispatcher(options({ environments: ['attacker-linux'] }), dependencies(api)),
    /outside the canonical matrix/u
  );
  await assert.rejects(
    () => runDispatcher(options({ requirements: [] }), dependencies(api)),
    /at least one canonical value/u
  );
  await assert.rejects(
    () => runDispatcher(options({ environments: [
      'ubuntu-24.04-gnome-x11-aarch64',
      'ubuntu-24.04-gnome-x11-aarch64'
    ] }), dependencies(api)),
    /must not contain duplicates/u
  );
});

test('wrong repo, workflow, ref, candidate, attempt, artifact, and pair mutations reject', async () => {
  const mutations = [
    (run) => { run.repository.full_name = 'attacker/repo'; },
    (run) => { run.head_repository.id += 1; },
    (run) => { run.workflow_id += 1; },
    (run) => { run.path = '.github/workflows/other.yml'; },
    (run) => { run.head_sha = 'd'.repeat(40); },
    (run) => { run.head_branch = 'other'; },
    (run) => { run.event = 'push'; },
    (run) => { run.run_attempt = 2; },
    (run) => { run.conclusion = null; }
  ];
  for (const mutate of mutations) {
    const run = parityRun({
      id: 200,
      requirement: 'P-01',
      environment: 'ubuntu-24.04-gnome-x11-x86_64'
    });
    mutate(run);
    const { api } = baseApi({ runs: [run] });
    await assert.rejects(() => runDispatcher(options(), dependencies(api)));
  }

  const run = parityRun({
    id: 201,
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-x86_64'
  });
  for (const mutateArtifact of [
    (artifact) => { artifact.name = artifact.name.replace(CANDIDATE_RUN_ID, '999'); },
    (artifact) => { artifact.expired = true; },
    (artifact) => { artifact.digest = 'sha256:bad'; },
    (artifact) => { artifact.workflow_run.head_sha = 'd'.repeat(40); },
    (artifact) => { artifact.name = artifact.name.replace('P-01', 'P-02'); }
  ]) {
    const artifact = parityArtifact(run);
    mutateArtifact(artifact);
    const { api } = baseApi({ runs: [run], artifacts: new Map([[run.id, [artifact]]]) });
    await assert.rejects(() => runDispatcher(options(), dependencies(api)));
  }

  const activeWithConclusion = parityRun({
    id: 202,
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-x86_64',
    status: 'queued',
    conclusion: 'failure'
  });
  await assert.rejects(
    () => runDispatcher(options(), dependencies(baseApi({ runs: [activeWithConclusion] }).api)),
    /must not have a conclusion/u
  );
});

test('a run must expose exactly one canonical matrix job, including duplicate-name rejection', async () => {
  const run = parityRun({
    id: 250,
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-x86_64',
    status: 'queued',
    conclusion: null
  });
  const name = `${run.__pair.requirement} on ${run.__pair.environment}`;
  const jobs = new Map([[run.id, [
    { id: 1, name },
    { id: 2, name }
  ]]]);
  await assert.rejects(
    () => runDispatcher(options(), dependencies(baseApi({ runs: [run], jobs }).api)),
    /exactly one matrix job/u
  );
});

test('duplicate successful and active pairs reject deterministically', async () => {
  const environment = 'ubuntu-24.04-gnome-x11-x86_64';
  for (const runs of [
    [
      parityRun({ id: 301, requirement: 'P-01', environment }),
      parityRun({ id: 302, requirement: 'P-01', environment })
    ],
    [
      parityRun({ id: 303, requirement: 'P-01', environment, status: 'queued', conclusion: null }),
      parityRun({ id: 304, requirement: 'P-01', environment, status: 'in_progress', conclusion: null })
    ],
    [
      parityRun({ id: 305, requirement: 'P-01', environment }),
      parityRun({ id: 306, requirement: 'P-01', environment, status: 'queued', conclusion: null })
    ]
  ]) {
    const { api } = baseApi({ runs });
    await assert.rejects(() => runDispatcher(options(), dependencies(api)), /duplicate|conflict/u);
  }
});

test('execute dispatches only available missing rows, rate limits, and persists each run', async () => {
  const running = parityRun({
    id: 401,
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-x86_64',
    status: 'in_progress',
    conclusion: null
  });
  const state = {
    schemaVersion: 1,
    repository: DISPATCH_POLICY.repository,
    workflowPath: DISPATCH_POLICY.workflowPath,
    targetRef: TARGET_REF,
    targetSha: TARGET_SHA,
    candidateRunId: CANDIDATE_RUN_ID,
    dispatches: [{
      runId: running.id,
      requirement: running.__pair.requirement,
      environment: running.__pair.environment,
      dispatchedAt: '2026-07-24T12:00:00.000Z'
    }]
  };
  let nextRun = 500;
  const { api, calls } = baseApi({
    runs: [running],
    dispatch: (body) => ({
      ...parityRun({
        id: nextRun += 1,
        requirement: body.inputs.requirement,
        environment: body.inputs.environment,
        status: 'queued',
        conclusion: null
      }),
      __pair: undefined
    })
  });
  const sleeps = [];
  const writes = [];
  let lockIdentity;
  const result = await runDispatcher(options({
    execute: true,
    maxConcurrency: 3,
    rateLimitMs: 250,
    stateFile: '/tmp/mock-parity-state.json'
  }), dependencies(api, {
    state,
    acquireStateLock: (file) => {
      lockIdentity = file;
      return () => {};
    },
    sleep: async (ms) => { sleeps.push(ms); },
    now: () => Date.parse('2026-07-24T13:00:00Z'),
    mkdirSync: () => {},
    writeFileSync: (file, contents, optionsValue) => { writes.push({ file, contents, optionsValue }); },
    renameSync: () => {}
  }));
  assert.equal(result.execution.dispatched.length, 2);
  assert.notEqual(lockIdentity, '/tmp/mock-parity-state.json');
  assert.match(lockIdentity, /linux-product-parity-dispatch-/u);
  assert.deepEqual(result.counts, {
    completed: 0,
    running: 1,
    queued: 2,
    failed: 0,
    missing: 277
  });
  assert.equal(result.plan.length, 277);
  assert.deepEqual(sleeps, [250]);
  assert.equal(writes.length, 4);
  assert.ok(writes.every((write) => write.optionsValue.mode === 0o600));
  assert.equal(JSON.parse(writes[0].contents).dispatches.at(-1).phase, 'pending');
  assert.equal(JSON.parse(writes[1].contents).dispatches.at(-1).phase, 'bound');
  const posts = calls.filter((call) => call.request.method === 'POST');
  assert.equal(posts.length, 2);
  assert.deepEqual(posts[0].request.body, {
    ref: TARGET_BRANCH,
    inputs: {
      requirement: 'P-01',
      environment: 'ubuntu-24.04-gnome-x11-aarch64',
      candidate_run_id: CANDIDATE_RUN_ID
    }
  });
});

test('execute selector bypasses unavailable earlier environments without hiding global activity', async () => {
  const running = parityRun({
    id: 550,
    requirement: 'P-35',
    environment: 'fedora-kde-wayland-x86_64',
    status: 'in_progress',
    conclusion: null
  });
  const state = {
    schemaVersion: 1,
    repository: DISPATCH_POLICY.repository,
    workflowPath: DISPATCH_POLICY.workflowPath,
    targetRef: TARGET_REF,
    targetSha: TARGET_SHA,
    candidateRunId: CANDIDATE_RUN_ID,
    dispatches: [{
      runId: running.id,
      requirement: running.__pair.requirement,
      environment: running.__pair.environment,
      dispatchedAt: '2026-07-24T12:00:00.000Z'
    }]
  };
  const { api, calls } = baseApi({ runs: [running] });
  const result = await runDispatcher(options({
    execute: true,
    maxConcurrency: 2,
    requirements: ['P-01'],
    environments: ['ubuntu-24.04-gnome-x11-aarch64'],
    stateFile: '/tmp/mock-selected-parity-state.json'
  }), dependencies(api, {
    state,
    now: () => Date.parse('2026-07-24T13:00:00Z'),
    randomUUID: () => 'nonce-selected-0001',
    mkdirSync: () => {},
    writeFileSync: () => {},
    renameSync: () => {}
  }));
  assert.equal(result.counts.running, 1);
  assert.equal(result.counts.queued, 1);
  assert.equal(result.execution.dispatched.length, 1);
  assert.equal(result.execution.remainingAfterPass, 0);
  const posts = calls.filter((call) => call.request.method === 'POST');
  assert.deepEqual(posts[0].request.body.inputs, {
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-aarch64',
    candidate_run_id: CANDIDATE_RUN_ID
  });
});

test('execute rejects unbound active runs and a ref move before dispatch', async () => {
  const active = parityRun({
    id: 601,
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-x86_64',
    status: 'queued',
    conclusion: null
  });
  const unbound = baseApi({ runs: [active] });
  await assert.rejects(
    () => runDispatcher(options({ execute: true }), dependencies(unbound.api)),
    /without persisted candidate binding/u
  );
  assert.equal(unbound.calls.some((call) => call.request.method === 'POST'), false);

  const moving = baseApi();
  let refReads = 0;
  const movingApi = (endpoint, request) => {
    if (endpoint.endsWith(`/git/ref/heads/${TARGET_BRANCH}`)) {
      refReads += 1;
      return {
        ref: TARGET_REF,
        object: { type: 'commit', sha: refReads === 1 ? TARGET_SHA : 'd'.repeat(40) }
      };
    }
    return moving.api(endpoint, request);
  };
  await assert.rejects(
    () => runDispatcher(options({ execute: true }), dependencies(movingApi, {
      state: {
        schemaVersion: 1,
        repository: DISPATCH_POLICY.repository,
        workflowPath: DISPATCH_POLICY.workflowPath,
        targetRef: TARGET_REF,
        targetSha: TARGET_SHA,
        candidateRunId: CANDIDATE_RUN_ID,
        dispatches: []
      }
    })),
    /target ref moved/u
  );
  assert.equal(moving.calls.some((call) => call.request.method === 'POST'), false);
});

test('execute revalidates immutable candidate evidence immediately before POST', async () => {
  const base = baseApi();
  let candidateArtifactReads = 0;
  const api = (endpoint, request = {}) => {
    const response = base.api(endpoint, request);
    if (endpoint.includes(`/actions/runs/${CANDIDATE_RUN_ID}/artifacts?name=`)) {
      candidateArtifactReads += 1;
      if (candidateArtifactReads > 1) {
        response.artifacts[0].digest = `sha256:${'d'.repeat(64)}`;
      }
    }
    return response;
  };
  await assert.rejects(
    () => runDispatcher(options({
      execute: true,
      maxConcurrency: 1,
      stateFile: '/tmp/mock-candidate-refresh-state.json'
    }), dependencies(api)),
    /candidate evidence changed/u
  );
  assert.equal(candidateArtifactReads, 2);
  assert.equal(base.calls.some((call) => call.request.method === 'POST'), false);
});

test('persisted state resumes a queued run before GitHub creates its matrix job', async () => {
  const queued = parityRun({
    id: 701,
    requirement: 'P-01',
    environment: 'ubuntu-24.04-gnome-x11-x86_64',
    status: 'queued',
    conclusion: null
  });
  const state = {
    schemaVersion: 1,
    repository: DISPATCH_POLICY.repository,
    workflowPath: DISPATCH_POLICY.workflowPath,
    targetRef: TARGET_REF,
    targetSha: TARGET_SHA,
    candidateRunId: CANDIDATE_RUN_ID,
    dispatches: [{
      runId: queued.id,
      requirement: queued.__pair.requirement,
      environment: queued.__pair.environment,
      dispatchedAt: '2026-07-24T13:00:00.000Z'
    }]
  };
  const { api } = baseApi({ runs: [queued], jobs: new Map([[queued.id, []]]) });
  const result = await runDispatcher(options(), dependencies(api, { state }));
  assert.equal(result.counts.queued, 1);
  assert.equal(result.status.queued[0].candidateBinding, 'persisted');
  assert.equal(result.plan.some((pair) => (
    pair.requirement === queued.__pair.requirement
    && pair.environment === queued.__pair.environment
  )), false);
});

test('empty successful gh API responses are accepted without JSON parsing', () => {
  const api = createGhApi(() => ({ status: 0, stdout: '', stderr: '' }));
  assert.equal(api('repos/owner/repo/actions/workflows/1/dispatches', {
    method: 'POST',
    body: { ref: 'main', inputs: {} }
  }), undefined);
});

test('execute polls through delayed workflow-run visibility after an empty dispatch response', async () => {
  const base = baseApi();
  let dispatched = false;
  let hiddenPolls = 0;
  const api = (endpoint, request = {}) => {
    if (request.method === 'POST') {
      dispatched = true;
      return base.api(endpoint, request);
    }
    if (dispatched
        && endpoint.includes(`/actions/workflows/${WORKFLOW_ID}/runs?`)
        && hiddenPolls === 0) {
      hiddenPolls += 1;
      return { total_count: 0, workflow_runs: [] };
    }
    return base.api(endpoint, request);
  };
  const sleeps = [];
  const result = await runDispatcher(options({
    execute: true,
    maxConcurrency: 1,
    pollAttempts: 3,
    pollIntervalMs: 25,
    stateFile: '/tmp/mock-delayed-parity-state.json'
  }), dependencies(api, {
    sleep: async (ms) => { sleeps.push(ms); },
    now: () => Date.parse('2026-07-24T13:00:00Z'),
    randomUUID: () => 'nonce-delayed-0001',
    mkdirSync: () => {},
    writeFileSync: () => {},
    renameSync: () => {}
  }));
  assert.equal(result.execution.dispatched.length, 1);
  assert.deepEqual(sleeps, [25]);
  assert.equal(hiddenPolls, 1);
});

test('execute rejects ambiguous post-dispatch run discovery', async () => {
  const runs = [];
  const base = baseApi({ runs });
  const api = (endpoint, request = {}) => {
    const response = base.api(endpoint, request);
    if (request.method === 'POST') {
      const duplicate = clone(runs.at(-1));
      duplicate.id += 1;
      duplicate.run_number += 1;
      runs.push(duplicate);
    }
    return response;
  };
  await assert.rejects(
    () => runDispatcher(options({
      execute: true,
      maxConcurrency: 1,
      pollAttempts: 1,
      stateFile: '/tmp/mock-ambiguous-parity-state.json'
    }), dependencies(api, {
      now: () => Date.parse('2026-07-24T13:00:00Z'),
      randomUUID: () => 'nonce-ambiguous-0001',
      mkdirSync: () => {},
      writeFileSync: () => {},
      renameSync: () => {}
    })),
    /dispatch discovery is ambiguous/u
  );
});

test('execute times out without redispatch when a run never becomes visible', async () => {
  const base = baseApi({ recordDispatch: false });
  const writes = [];
  await assert.rejects(
    () => runDispatcher(options({
      execute: true,
      maxConcurrency: 1,
      pollAttempts: 2,
      pollIntervalMs: 0,
      stateFile: '/tmp/mock-timeout-parity-state.json'
    }), dependencies(base.api, {
      now: () => Date.parse('2026-07-24T13:00:00Z'),
      randomUUID: () => 'nonce-timeout-0001',
      mkdirSync: () => {},
      writeFileSync: (_file, contents) => { writes.push(JSON.parse(contents)); },
      renameSync: () => {}
    })),
    /dispatch discovery timed out/u
  );
  assert.equal(base.calls.filter((call) => call.request.method === 'POST').length, 1);
  assert.equal(writes.length, 1);
  assert.equal(writes[0].dispatches[0].phase, 'pending');
});

test('crash after empty POST resumes pending discovery without a duplicate dispatch', async () => {
  const base = baseApi();
  const firstWrites = [];
  const crashingApi = (endpoint, request = {}) => {
    const response = base.api(endpoint, request);
    if (request.method === 'POST') throw new Error('simulated crash after accepted dispatch');
    return response;
  };
  await assert.rejects(
    () => runDispatcher(options({
      execute: true,
      maxConcurrency: 1,
      stateFile: '/tmp/mock-crash-parity-state.json'
    }), dependencies(crashingApi, {
      now: () => Date.parse('2026-07-24T13:00:00Z'),
      randomUUID: () => 'nonce-crash-0001',
      mkdirSync: () => {},
      writeFileSync: (_file, contents) => { firstWrites.push(JSON.parse(contents)); },
      renameSync: () => {}
    })),
    /simulated crash/u
  );
  assert.equal(firstWrites.length, 1);
  assert.equal(firstWrites[0].dispatches[0].phase, 'pending');
  assert.equal(base.calls.filter((call) => call.request.method === 'POST').length, 1);

  const resumeWrites = [];
  const result = await runDispatcher(options({
    execute: true,
    maxConcurrency: 1,
    stateFile: '/tmp/mock-crash-parity-state.json'
  }), dependencies(base.api, {
    state: firstWrites[0],
    now: () => Date.parse('2026-07-24T13:00:02Z'),
    mkdirSync: () => {},
    writeFileSync: (_file, contents) => { resumeWrites.push(JSON.parse(contents)); },
    renameSync: () => {}
  }));
  assert.equal(result.execution.recovered.length, 1);
  assert.equal(result.execution.dispatched.length, 0);
  assert.equal(resumeWrites[0].dispatches[0].phase, 'bound');
  assert.equal(base.calls.filter((call) => call.request.method === 'POST').length, 1);
});

test('state lock excludes live writers and ignores only descriptor-validated dead owners', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'parity-dispatch-lock-'));
  const stateFile = path.join(root, 'state.json');
  const lockDirectory = `${stateFile}.locks`;
  const deadNonce = 'a'.repeat(32);
  const deadName = `2147483647-${deadNonce}.lock`;
  const deadFile = path.join(lockDirectory, deadName);
  try {
    const release = acquireStateLock(stateFile);
    assert.throws(
      () => acquireStateLock(stateFile),
      /locked by active process/u
    );
    release();
    release();
    assert.deepEqual(fs.readdirSync(lockDirectory), []);

    fs.writeFileSync(deadFile, JSON.stringify({
      schemaVersion: 1,
      pid: 2_147_483_647,
      nonce: deadNonce,
      acquiredAt: '2026-07-24T13:00:00.000Z'
    }), { mode: 0o600, flag: 'wx' });
    const releaseRecovered = acquireStateLock(stateFile, {
      kill: () => {
        const error = new Error('no such process');
        error.code = 'ESRCH';
        throw error;
      }
    });
    const recoveredLockNames = fs.readdirSync(lockDirectory);
    assert.equal(recoveredLockNames.length, 2);
    assert.ok(recoveredLockNames.includes(deadName));
    releaseRecovered();
    assert.deepEqual(fs.readdirSync(lockDirectory), [deadName]);
    fs.unlinkSync(deadFile);

    // An owner that releases after the directory scan is ignored by its
    // descriptor open; the caller still retains its independently named lock.
    fs.writeFileSync(deadFile, JSON.stringify({
      schemaVersion: 1,
      pid: 2_147_483_647,
      nonce: deadNonce,
      acquiredAt: '2026-07-24T13:00:00.000Z'
    }), { mode: 0o600, flag: 'wx' });
    let openAttempts = 0;
    const releaseRaced = acquireStateLock(stateFile, {
      openSync: (...args) => {
        openAttempts += 1;
        if (args[0] === deadFile) {
          fs.unlinkSync(deadFile);
          const error = new Error('vanished');
          error.code = 'ENOENT';
          throw error;
        }
        return fs.openSync(...args);
      }
    });
    assert.equal(openAttempts, 2);
    assert.equal(fs.readdirSync(lockDirectory).length, 1);
    releaseRaced();
    assert.deepEqual(fs.readdirSync(lockDirectory), []);

    const target = path.join(root, 'outside-lock');
    fs.writeFileSync(target, '{}', { mode: 0o600, flag: 'wx' });
    fs.symlinkSync(target, deadFile);
    assert.throws(
      () => acquireStateLock(stateFile),
      /unreadable|symlink|ELOOP/u
    );
    fs.unlinkSync(deadFile);
    assert.deepEqual(fs.readdirSync(lockDirectory), []);

    fs.writeFileSync(deadFile, JSON.stringify({
      schemaVersion: 1,
      pid: 2_147_483_647,
      nonce: deadNonce,
      acquiredAt: '2026-07-24T13:00:00.000Z'
    }), { mode: 0o644, flag: 'wx' });
    assert.throws(
      () => acquireStateLock(stateFile),
      /owner-only bounded regular file/u
    );
    fs.unlinkSync(deadFile);
    assert.deepEqual(fs.readdirSync(lockDirectory), []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('gh adapter passes endpoint and JSON body as argv/stdin without a shell', () => {
  const executions = [];
  const api = createGhApi((command, args, optionsValue) => {
    executions.push({ command, args, optionsValue });
    return { status: 0, stdout: '{"ok":true}', stderr: '' };
  });
  const body = {
    ref: 'branch; touch /tmp/never',
    inputs: { requirement: '$(false)', environment: '`false`' }
  };
  assert.deepEqual(api('repos/owner/repo/actions/workflows/1/dispatches', {
    method: 'POST',
    body
  }), { ok: true });
  assert.equal(executions[0].command, 'gh');
  assert.deepEqual(executions[0].args, [
    'api',
    '--method',
    'POST',
    'repos/owner/repo/actions/workflows/1/dispatches',
    '--input',
    '-'
  ]);
  assert.equal(executions[0].optionsValue.input, JSON.stringify(body));
  assert.equal('shell' in executions[0].optionsValue, false);
});
