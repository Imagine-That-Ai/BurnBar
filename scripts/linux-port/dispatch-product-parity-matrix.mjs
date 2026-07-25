#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  EVIDENCE_POLICY,
  resolveProductEvidenceRun
} from './resolve-product-evidence-run.mjs';

export const DISPATCH_POLICY = Object.freeze({
  repository: EVIDENCE_POLICY.repository,
  workflowName: 'Linux product parity evidence',
  workflowPath: '.github/workflows/linux-product-parity.yml',
  requirementsManifest: 'docs/linux-port/product-parity-requirements.json',
  evidencePolicies: 'docs/linux-port/product-parity-evidence-policies.json',
  artifactPrefix: 'linux-product-parity-',
  requirementCount: 40,
  environmentCount: 7,
  defaultMaxConcurrency: 4,
  defaultRateLimitMs: 1_000,
  defaultPollAttempts: 12,
  defaultPollIntervalMs: 5_000,
  maximumConcurrency: 20,
  maximumRateLimitMs: 60_000,
  maximumPollAttempts: 120
});

const SHA_PATTERN = /^[a-f0-9]{40}$/u;
const RUN_ID_PATTERN = /^[1-9][0-9]*$/u;
const REQUIREMENT_PATTERN = /^P-(?:0[1-9]|[1-3][0-9]|40)$/u;
const ENVIRONMENT_PATTERN = /^[a-z0-9][a-z0-9._-]*$/u;
const REF_PATTERN = /^refs\/(?:heads|tags)\/[A-Za-z0-9][A-Za-z0-9._/-]*$/u;
const ACTIVE_STATUSES = new Set(['in_progress']);
const QUEUED_STATUSES = new Set(['pending', 'queued', 'requested', 'waiting']);
const COMPLETED_CONCLUSIONS = new Set([
  'action_required',
  'cancelled',
  'failure',
  'neutral',
  'skipped',
  'stale',
  'startup_failure',
  'success',
  'timed_out'
]);
const CANONICAL_ENVIRONMENTS = Object.freeze([
  'ubuntu-24.04-gnome-x11-x86_64',
  'ubuntu-24.04-gnome-x11-aarch64',
  'ubuntu-24.04-gnome-wayland-x86_64',
  'ubuntu-24.04-gnome-wayland-aarch64',
  'fedora-kde-wayland-x86_64',
  'fedora-kde-wayland-aarch64',
  'arch-sway-wayland-x86_64'
]);

function requiredObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function requiredArray(value, label) {
  if (!Array.isArray(value)) throw new Error(`${label} must be an array`);
  return value;
}

function requiredString(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value.trim() !== value) {
    throw new Error(`${label} must be a nonempty string without surrounding whitespace`);
  }
  return value;
}

function requiredSafeInteger(value, label) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${label} must be a positive safe integer`);
  }
  return value;
}

function sameStrings(actual, expected) {
  return actual.length === expected.length
    && actual.every((value, index) => value === expected[index]);
}

function pairKey(requirement, environment) {
  return `${requirement}\0${environment}`;
}

function sortedPairs(pairs) {
  return [...pairs];
}

function canonicalRequirements() {
  return Array.from(
    { length: DISPATCH_POLICY.requirementCount },
    (_, index) => `P-${String(index + 1).padStart(2, '0')}`
  );
}

function parseSelectorList(value, label, pattern) {
  requiredString(value, label);
  const entries = value.split(',');
  if (entries.some((entry) => entry.length === 0 || !pattern.test(entry))) {
    throw new Error(`${label} must be a comma-separated list of canonical values`);
  }
  if (new Set(entries).size !== entries.length) {
    throw new Error(`${label} must not contain duplicates`);
  }
  return entries;
}

function selectCanonical(values, canonical, label) {
  if (values === undefined) return canonical;
  if (!Array.isArray(values) || values.length === 0) {
    throw new Error(`${label} must contain at least one canonical value`);
  }
  for (const value of values) requiredString(value, label);
  if (new Set(values).size !== values.length) {
    throw new Error(`${label} must not contain duplicates`);
  }
  if (values.some((value) => !canonical.includes(value))) {
    throw new Error(`${label} contains a value outside the canonical matrix`);
  }
  return values;
}

export function validateCanonicalMatrix(requirementsManifest, evidencePolicies) {
  requiredObject(requirementsManifest, 'requirements manifest');
  requiredObject(evidencePolicies, 'evidence policies');
  if (requirementsManifest.schemaVersion !== 1
      || requirementsManifest.id !== 'openburnbar-linux-macos-parity-v1') {
    throw new Error('requirements manifest identity or schema is not canonical');
  }
  const policy = requiredObject(requirementsManifest.policy, 'requirements manifest policy');
  for (const key of [
    'allRequirementsMandatory',
    'missingCapabilitiesMayNotBeDocumentedAway',
    'readyEvidenceMustMatchTargetHead',
    'minimumSupportRowsMayNotBeAllowBlocked'
  ]) {
    if (policy[key] !== true) throw new Error(`requirements manifest policy ${key} must be true`);
  }

  const requirements = requiredArray(requirementsManifest.requirements, 'requirements');
  const requirementIds = requirements.map((entry, index) => {
    const row = requiredObject(entry, `requirement ${index + 1}`);
    if (!REQUIREMENT_PATTERN.test(row.id ?? '')) {
      throw new Error(`requirement ${index + 1} has a noncanonical id`);
    }
    return row.id;
  });
  const expectedRequirements = canonicalRequirements();
  if (!sameStrings(requirementIds, expectedRequirements)) {
    throw new Error('requirements manifest must contain ordered P-01 through P-40 exactly once');
  }

  const environments = requiredArray(
    requirementsManifest.minimumSupportMatrix,
    'minimum support matrix'
  );
  if (environments.length !== DISPATCH_POLICY.environmentCount) {
    throw new Error(`minimum support matrix must contain ${DISPATCH_POLICY.environmentCount} rows`);
  }
  const environmentIds = environments.map((entry, index) => {
    const row = requiredObject(entry, `minimum support row ${index + 1}`);
    if (!ENVIRONMENT_PATTERN.test(row.id ?? '')) {
      throw new Error(`minimum support row ${index + 1} has a noncanonical id`);
    }
    for (const field of ['os', 'desktop', 'session', 'architecture']) {
      requiredString(row[field], `minimum support row ${row.id} ${field}`);
    }
    return row.id;
  });
  if (new Set(environmentIds).size !== environmentIds.length) {
    throw new Error('minimum support matrix contains duplicate environments');
  }
  if (!sameStrings(environmentIds, CANONICAL_ENVIRONMENTS)) {
    throw new Error('minimum support matrix must contain the ordered canonical environments');
  }

  if (evidencePolicies.schemaVersion !== 1
      || evidencePolicies.id !== 'openburnbar-linux-product-parity-evidence-policies-v1'
      || evidencePolicies.requirementsManifest !== DISPATCH_POLICY.requirementsManifest) {
    throw new Error('evidence policy identity, schema, or requirements binding is not canonical');
  }
  const rows = requiredArray(evidencePolicies.policies, 'evidence policy rows');
  if (rows.length !== DISPATCH_POLICY.requirementCount) {
    throw new Error(`evidence policies must contain ${DISPATCH_POLICY.requirementCount} rows`);
  }
  const byRequirement = new Map();
  for (const [index, entry] of rows.entries()) {
    const row = requiredObject(entry, `evidence policy row ${index + 1}`);
    if (!REQUIREMENT_PATTERN.test(row.requirementId ?? '') || byRequirement.has(row.requirementId)) {
      throw new Error(`evidence policy row ${index + 1} has a duplicate or noncanonical requirement`);
    }
    if (row.policyVersion !== 1) {
      throw new Error(`evidence policy ${row.requirementId} has an unsupported version`);
    }
    if (!sameStrings(requiredArray(
      row.requiredEnvironmentIds,
      `evidence policy ${row.requirementId} environments`
    ), environmentIds)) {
      throw new Error(`evidence policy ${row.requirementId} does not require the canonical matrix`);
    }
    const producer = requiredObject(
      row.registeredProducer,
      `evidence policy ${row.requirementId} producer`
    );
    if (producer.repository !== DISPATCH_POLICY.repository
        || producer.signerWorkflow
          !== `github.com/${DISPATCH_POLICY.repository}/${DISPATCH_POLICY.workflowPath}`) {
      throw new Error(`evidence policy ${row.requirementId} has the wrong producer identity`);
    }
    if (requiredArray(row.requiredCheckIds, `${row.requirementId} checks`).length === 0) {
      throw new Error(`evidence policy ${row.requirementId} has no required checks`);
    }
    byRequirement.set(row.requirementId, row);
  }
  if (!sameStrings([...byRequirement.keys()].sort(), expectedRequirements)) {
    throw new Error('evidence policies do not cover every canonical requirement');
  }

  return {
    requirements: expectedRequirements,
    environments: environmentIds,
    pairs: expectedRequirements.flatMap((requirement) => (
      environmentIds.map((environment) => ({ requirement, environment }))
    ))
  };
}

export function parseArguments(argv) {
  const options = {
    execute: false,
    maxConcurrency: DISPATCH_POLICY.defaultMaxConcurrency,
    rateLimitMs: DISPATCH_POLICY.defaultRateLimitMs,
    pollAttempts: DISPATCH_POLICY.defaultPollAttempts,
    pollIntervalMs: DISPATCH_POLICY.defaultPollIntervalMs,
    requirements: undefined,
    environments: undefined,
    stateFile: undefined
  };
  const seen = new Set();
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === '--execute') {
      if (seen.has(flag)) throw new Error('--execute may be specified only once');
      seen.add(flag);
      options.execute = true;
      continue;
    }
    if (![
      '--ref',
      '--candidate-run-id',
      '--max-concurrency',
      '--rate-ms',
      '--poll-attempts',
      '--poll-ms',
      '--requirements',
      '--environments',
      '--state-file'
    ]
      .includes(flag)) {
      throw new Error(`unknown argument: ${flag}`);
    }
    if (seen.has(flag)) throw new Error(`${flag} may be specified only once`);
    seen.add(flag);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) throw new Error(`${flag} requires a value`);
    index += 1;
    if (flag === '--ref') options.targetRef = value;
    if (flag === '--candidate-run-id') options.candidateRunId = value;
    if (flag === '--requirements') {
      options.requirements = parseSelectorList(value, '--requirements', REQUIREMENT_PATTERN);
    }
    if (flag === '--environments') {
      options.environments = parseSelectorList(value, '--environments', ENVIRONMENT_PATTERN);
    }
    if (flag === '--state-file') options.stateFile = value;
    if (flag === '--max-concurrency') options.maxConcurrency = Number(value);
    if (flag === '--rate-ms') options.rateLimitMs = Number(value);
    if (flag === '--poll-attempts') options.pollAttempts = Number(value);
    if (flag === '--poll-ms') options.pollIntervalMs = Number(value);
  }
  if (!options.targetRef) throw new Error('--ref is required');
  if (!options.candidateRunId) throw new Error('--candidate-run-id is required');
  validateTargetRef(options.targetRef);
  if (!RUN_ID_PATTERN.test(options.candidateRunId)
      || !Number.isSafeInteger(Number(options.candidateRunId))) {
    throw new Error('--candidate-run-id must be a positive canonical safe integer');
  }
  if (!Number.isSafeInteger(options.maxConcurrency)
      || options.maxConcurrency < 1
      || options.maxConcurrency > DISPATCH_POLICY.maximumConcurrency) {
    throw new Error(`--max-concurrency must be between 1 and ${DISPATCH_POLICY.maximumConcurrency}`);
  }
  if (!Number.isSafeInteger(options.rateLimitMs)
      || options.rateLimitMs < 0
      || options.rateLimitMs > DISPATCH_POLICY.maximumRateLimitMs) {
    throw new Error(`--rate-ms must be between 0 and ${DISPATCH_POLICY.maximumRateLimitMs}`);
  }
  if (!Number.isSafeInteger(options.pollAttempts)
      || options.pollAttempts < 1
      || options.pollAttempts > DISPATCH_POLICY.maximumPollAttempts) {
    throw new Error(`--poll-attempts must be between 1 and ${DISPATCH_POLICY.maximumPollAttempts}`);
  }
  if (!Number.isSafeInteger(options.pollIntervalMs)
      || options.pollIntervalMs < 0
      || options.pollIntervalMs > DISPATCH_POLICY.maximumRateLimitMs) {
    throw new Error(`--poll-ms must be between 0 and ${DISPATCH_POLICY.maximumRateLimitMs}`);
  }
  if (options.stateFile !== undefined) {
    requiredString(options.stateFile, '--state-file');
    if (options.stateFile.includes('\0')) throw new Error('--state-file contains a null byte');
  }
  return options;
}

export function validateTargetRef(ref) {
  requiredString(ref, 'target ref');
  if (!REF_PATTERN.test(ref)
      || ref.includes('..')
      || ref.includes('//')
      || ref.includes('@{')
      || ref.endsWith('/')) {
    throw new Error('target ref must be a canonical refs/heads/... or refs/tags/... value');
  }
  return ref;
}

function refApiPath(ref) {
  return ref.slice('refs/'.length).split('/').map(encodeURIComponent).join('/');
}

export function resolveTargetRef(api, ref) {
  validateTargetRef(ref);
  const response = requiredObject(
    api(`repos/${DISPATCH_POLICY.repository}/git/ref/${refApiPath(ref)}`),
    'target ref response'
  );
  if (response.ref !== ref) throw new Error('target ref response does not match the requested ref');
  let object = requiredObject(response.object, 'target ref object');
  const seen = new Set();
  while (object.type === 'tag') {
    if (!SHA_PATTERN.test(object.sha ?? '') || seen.has(object.sha) || seen.size >= 5) {
      throw new Error('target annotated tag chain is invalid');
    }
    seen.add(object.sha);
    const tag = requiredObject(
      api(`repos/${DISPATCH_POLICY.repository}/git/tags/${object.sha}`),
      'annotated tag response'
    );
    if (tag.sha !== object.sha) throw new Error('annotated tag response does not match the target');
    object = requiredObject(tag.object, 'annotated tag target');
  }
  if (object.type !== 'commit' || !SHA_PATTERN.test(object.sha ?? '')) {
    throw new Error('target ref must resolve to an exact lowercase commit SHA');
  }
  return {
    ref,
    dispatchRef: ref.replace(/^refs\/(?:heads|tags)\//u, ''),
    sha: object.sha
  };
}

export function validateWorkflow(workflow) {
  requiredObject(workflow, 'workflow');
  requiredSafeInteger(workflow.id, 'workflow id');
  if (workflow.name !== DISPATCH_POLICY.workflowName
      || workflow.path !== DISPATCH_POLICY.workflowPath
      || workflow.state !== 'active') {
    throw new Error('workflow identity, path, or state is not trusted');
  }
  return { id: workflow.id, name: workflow.name, path: workflow.path };
}

function validateRunIdentity(run, context) {
  requiredObject(run, 'parity workflow run');
  requiredSafeInteger(run.id, 'parity workflow run id');
  const repository = requiredObject(run.repository, 'parity workflow run repository');
  const headRepository = requiredObject(
    run.head_repository,
    'parity workflow run head repository'
  );
  if (repository.full_name !== DISPATCH_POLICY.repository
      || headRepository.full_name !== DISPATCH_POLICY.repository
      || !Number.isSafeInteger(repository.id)
      || repository.id !== headRepository.id) {
    throw new Error(`parity workflow run ${run.id} has the wrong repository identity`);
  }
  if (run.workflow_id !== context.workflow.id || run.path !== DISPATCH_POLICY.workflowPath) {
    throw new Error(`parity workflow run ${run.id} has the wrong workflow identity`);
  }
  if (run.event !== 'workflow_dispatch'
      || run.head_sha !== context.target.sha
      || run.head_branch !== context.target.dispatchRef) {
    throw new Error(`parity workflow run ${run.id} has the wrong event, ref, or target SHA`);
  }
  if (run.run_attempt !== 1) {
    throw new Error(`parity workflow run ${run.id} is not a first attempt`);
  }
  if (run.status !== 'completed'
      && !ACTIVE_STATUSES.has(run.status)
      && !QUEUED_STATUSES.has(run.status)) {
    throw new Error(`parity workflow run ${run.id} has an unsupported status`);
  }
  if (run.status === 'completed' && !COMPLETED_CONCLUSIONS.has(run.conclusion)) {
    throw new Error(`parity workflow run ${run.id} has an unsupported conclusion`);
  }
  if (run.status !== 'completed' && run.conclusion !== null) {
    throw new Error(`active parity workflow run ${run.id} must not have a conclusion`);
  }
  return run;
}

function parseJobPair(jobs, matrix, runId) {
  requiredObject(jobs, `jobs response for run ${runId}`);
  const candidates = requiredArray(jobs.jobs, `jobs for run ${runId}`)
    .filter((job) => typeof job?.name === 'string')
    .map((job) => {
      const match = /^(P-(?:0[1-9]|[1-3][0-9]|40)) on ([a-z0-9][a-z0-9._-]*)$/u.exec(job.name);
      return match ? { requirement: match[1], environment: match[2] } : undefined;
    })
    .filter(Boolean);
  if (candidates.length === 0) return undefined;
  if (candidates.length !== 1) {
    throw new Error(`parity workflow run ${runId} does not expose exactly one matrix job`);
  }
  const pair = candidates[0];
  if (!matrix.requirements.includes(pair.requirement)
      || !matrix.environments.includes(pair.environment)) {
    throw new Error(`parity workflow run ${runId} exposes a noncanonical matrix pair`);
  }
  return pair;
}

function parseArtifactPair(artifact, context, run) {
  requiredObject(artifact, `artifact for run ${run.id}`);
  const workflowRun = requiredObject(artifact.workflow_run, `artifact workflow run ${run.id}`);
  if (String(workflowRun.id) !== String(run.id)
      || workflowRun.head_sha !== context.target.sha
      || workflowRun.repository_id !== run.repository.id
      || workflowRun.head_repository_id !== run.repository.id) {
    throw new Error(`artifact for run ${run.id} is not bound to the trusted run`);
  }
  const prefix = `${DISPATCH_POLICY.artifactPrefix}${context.target.sha}-`;
  if (typeof artifact.name !== 'string' || !artifact.name.startsWith(prefix)) return undefined;
  const remainder = artifact.name.slice(prefix.length);
  const match = /^([1-9][0-9]*)-(P-(?:0[1-9]|[1-3][0-9]|40))-([a-z0-9][a-z0-9._-]*)$/u
    .exec(remainder);
  if (!match) throw new Error(`run ${run.id} has a malformed canonical parity artifact name`);
  if (match[1] !== context.candidate.runId) {
    throw new Error(`run ${run.id} is bound to the wrong release candidate`);
  }
  if (!Number.isSafeInteger(artifact.id)
      || artifact.id <= 0
      || artifact.expired !== false
      || !Number.isSafeInteger(artifact.size_in_bytes)
      || artifact.size_in_bytes <= 0
      || !/^sha256:[a-f0-9]{64}$/u.test(artifact.digest ?? '')) {
    throw new Error(`run ${run.id} has an invalid canonical parity artifact`);
  }
  const expiresAt = new Date(artifact.expires_at);
  if (!Number.isFinite(expiresAt.getTime()) || expiresAt <= new Date()) {
    throw new Error(`run ${run.id} has an expired canonical parity artifact`);
  }
  return { requirement: match[2], environment: match[3] };
}

function validateArtifacts(response, context, run, pair) {
  requiredObject(response, `artifact response for run ${run.id}`);
  const parsed = requiredArray(response.artifacts, `artifacts for run ${run.id}`)
    .map((artifact) => parseArtifactPair(artifact, context, run))
    .filter(Boolean);
  if (parsed.length > 1) throw new Error(`run ${run.id} has duplicate canonical parity artifacts`);
  if (parsed.length === 1
      && pairKey(parsed[0].requirement, parsed[0].environment)
        !== pairKey(pair.requirement, pair.environment)) {
    throw new Error(`run ${run.id} job and artifact matrix pairs disagree`);
  }
  if (run.status === 'completed' && run.conclusion === 'success' && parsed.length !== 1) {
    throw new Error(`successful run ${run.id} is missing its canonical parity artifact`);
  }
  return parsed[0];
}

function validateState(state, context, matrix) {
  if (state === undefined) return { byRun: new Map(), entries: new Map(), pending: [] };
  requiredObject(state, 'dispatcher state');
  if (state.schemaVersion !== 1
      || state.repository !== DISPATCH_POLICY.repository
      || state.workflowPath !== DISPATCH_POLICY.workflowPath
      || state.targetRef !== context.target.ref
      || state.targetSha !== context.target.sha
      || state.candidateRunId !== context.candidate.runId) {
    throw new Error('dispatcher state is not bound to this repository, workflow, ref, SHA, and candidate');
  }
  const byRun = new Map();
  const entries = new Map();
  const pendingPairs = new Set();
  for (const [index, entry] of requiredArray(state.dispatches, 'dispatcher state dispatches').entries()) {
    requiredObject(entry, `dispatcher state entry ${index + 1}`);
    if (!matrix.requirements.includes(entry.requirement)
        || !matrix.environments.includes(entry.environment)) {
      throw new Error(`dispatcher state entry ${index + 1} is duplicate or noncanonical`);
    }
    const phase = entry.phase ?? 'bound';
    const nonce = entry.nonce ?? `legacy-${entry.runId}`;
    if (!/^[A-Za-z0-9-]{8,100}$/u.test(nonce) || entries.has(nonce)) {
      throw new Error(`dispatcher state entry ${index + 1} has an invalid or duplicate nonce`);
    }
    const normalized = {
      phase,
      nonce,
      requirement: entry.requirement,
      environment: entry.environment,
      dispatchStartedAt: entry.dispatchStartedAt ?? entry.dispatchedAt,
      dispatchedAt: entry.dispatchedAt,
      excludedRunIds: entry.excludedRunIds
    };
    if (phase === 'pending') {
      const pendingKey = pairKey(entry.requirement, entry.environment);
      if (entry.runId !== undefined || pendingPairs.has(pendingKey)) {
        throw new Error(`dispatcher state entry ${index + 1} is an invalid duplicate pending pair`);
      }
      if (!Number.isFinite(new Date(normalized.dispatchStartedAt).getTime())) {
        throw new Error(`dispatcher state entry ${index + 1} has an invalid dispatch start time`);
      }
      if (!Array.isArray(normalized.excludedRunIds)
          || normalized.excludedRunIds.some((runId) => (
            !Number.isSafeInteger(runId) || runId <= 0
          ))
          || new Set(normalized.excludedRunIds).size !== normalized.excludedRunIds.length) {
        throw new Error(`dispatcher state entry ${index + 1} has invalid excluded run ids`);
      }
      pendingPairs.add(pendingKey);
    } else if (phase === 'bound') {
      requiredSafeInteger(entry.runId, `dispatcher state entry ${index + 1} run id`);
      if (byRun.has(entry.runId)) {
        throw new Error(`dispatcher state entry ${index + 1} has a duplicate run id`);
      }
      normalized.runId = entry.runId;
      byRun.set(entry.runId, {
        requirement: entry.requirement,
        environment: entry.environment,
        candidateRunId: state.candidateRunId
      });
    } else {
      throw new Error(`dispatcher state entry ${index + 1} has an invalid phase`);
    }
    entries.set(nonce, normalized);
  }
  return {
    byRun,
    entries,
    pending: [...entries.values()].filter((entry) => entry.phase === 'pending')
  };
}

function listAll(api, endpoint, property) {
  const values = [];
  let totalCount;
  for (let page = 1; page <= 100; page += 1) {
    const separator = endpoint.includes('?') ? '&' : '?';
    const response = requiredObject(api(`${endpoint}${separator}per_page=100&page=${page}`), property);
    if (!Number.isSafeInteger(response.total_count) || response.total_count < 0) {
      throw new Error(`${property} total_count is invalid`);
    }
    if (totalCount === undefined) totalCount = response.total_count;
    if (response.total_count !== totalCount) throw new Error(`${property} changed during pagination`);
    const pageValues = requiredArray(response[property], property);
    values.push(...pageValues);
    if (values.length >= totalCount) break;
    if (pageValues.length === 0) throw new Error(`${property} pagination ended before total_count`);
  }
  if (values.length !== totalCount) throw new Error(`${property} pagination is incomplete`);
  return values;
}

function loadState(stateFile, readFileSyncImpl = fs.readFileSync) {
  if (!stateFile || !fs.existsSync(stateFile)) return undefined;
  try {
    return JSON.parse(readFileSyncImpl(stateFile, 'utf8'));
  } catch (error) {
    throw new Error(`could not read dispatcher state: ${error.message}`);
  }
}

export function acquireStateLock(stateFile, dependencies = {}) {
  const mkdirSyncImpl = dependencies.mkdirSync ?? fs.mkdirSync;
  const openSyncImpl = dependencies.openSync ?? fs.openSync;
  const writeFileSyncImpl = dependencies.writeFileSync ?? fs.writeFileSync;
  const readFileSyncImpl = dependencies.readFileSync ?? fs.readFileSync;
  const closeSyncImpl = dependencies.closeSync ?? fs.closeSync;
  const unlinkSyncImpl = dependencies.unlinkSync ?? fs.unlinkSync;
  const killImpl = dependencies.kill ?? process.kill.bind(process);
  const pid = dependencies.pid ?? process.pid;
  const lockFile = `${stateFile}.lock`;
  mkdirSyncImpl(path.dirname(lockFile), { recursive: true });

  let descriptor;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      descriptor = openSyncImpl(lockFile, 'wx', 0o600);
      break;
    } catch (error) {
      if (error?.code !== 'EEXIST' || attempt > 0) throw error;
      let owner;
      try {
        owner = JSON.parse(readFileSyncImpl(lockFile, 'utf8'));
      } catch (readError) {
        throw new Error(`dispatcher state lock is unreadable: ${readError.message}`);
      }
      if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0) {
        throw new Error('dispatcher state lock has an invalid owner');
      }
      let ownerAlive = true;
      try {
        killImpl(owner.pid, 0);
      } catch (signalError) {
        if (signalError?.code === 'ESRCH') ownerAlive = false;
        else if (signalError?.code !== 'EPERM') throw signalError;
      }
      if (ownerAlive) {
        throw new Error(`dispatcher state is locked by active process ${owner.pid}`);
      }
      unlinkSyncImpl(lockFile);
    }
  }
  if (descriptor === undefined) throw new Error('could not acquire dispatcher state lock');
  try {
    writeFileSyncImpl(descriptor, `${JSON.stringify({
      schemaVersion: 1,
      pid,
      acquiredAt: new Date(dependencies.now?.() ?? Date.now()).toISOString()
    })}\n`, { encoding: 'utf8' });
  } catch (error) {
    closeSyncImpl(descriptor);
    unlinkSyncImpl(lockFile);
    throw error;
  }

  let released = false;
  return () => {
    if (released) return;
    released = true;
    closeSyncImpl(descriptor);
    unlinkSyncImpl(lockFile);
  };
}

function stateDocument(context, dispatches) {
  return {
    schemaVersion: 1,
    repository: DISPATCH_POLICY.repository,
    workflowPath: DISPATCH_POLICY.workflowPath,
    targetRef: context.target.ref,
    targetSha: context.target.sha,
    candidateRunId: context.candidate.runId,
    dispatches: [...dispatches.values()]
      .sort((left, right) => (
        String(left.dispatchStartedAt ?? '').localeCompare(String(right.dispatchStartedAt ?? ''))
        || left.nonce.localeCompare(right.nonce)
      ))
      .map(({
        phase,
        nonce,
        runId,
        requirement,
        environment,
        dispatchStartedAt,
        dispatchedAt,
        excludedRunIds
      }) => ({
        phase,
        nonce,
        ...(runId === undefined ? {} : { runId }),
        requirement,
        environment,
        dispatchStartedAt,
        dispatchedAt,
        ...(phase === 'pending' ? { excludedRunIds } : {})
      }))
  };
}

function writeState(file, document, dependencies = {}) {
  const mkdirSyncImpl = dependencies.mkdirSync ?? fs.mkdirSync;
  const writeFileSyncImpl = dependencies.writeFileSync ?? fs.writeFileSync;
  const renameSyncImpl = dependencies.renameSync ?? fs.renameSync;
  mkdirSyncImpl(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}`;
  writeFileSyncImpl(temporary, `${JSON.stringify(document, null, 2)}\n`, {
    encoding: 'utf8',
    mode: 0o600,
    flag: 'wx'
  });
  renameSyncImpl(temporary, file);
}

export function collectMatrixStatus({ api, matrix, context, state }) {
  const stateByRun = validateState(state, context, matrix).byRun;
  const runs = listAll(
    api,
    `repos/${DISPATCH_POLICY.repository}/actions/workflows/${context.workflow.id}/runs`
      + `?event=workflow_dispatch&head_sha=${context.target.sha}`,
    'workflow_runs'
  );
  const seenRunIds = new Set();
  const records = [];
  for (const runValue of runs) {
    const run = validateRunIdentity(runValue, context);
    if (seenRunIds.has(run.id)) throw new Error(`duplicate parity workflow run id ${run.id}`);
    seenRunIds.add(run.id);
    const statePair = stateByRun.get(run.id);
    const jobs = listAll(
      api,
      `repos/${DISPATCH_POLICY.repository}/actions/runs/${run.id}/jobs?filter=latest`,
      'jobs'
    );
    const jobPair = parseJobPair({ total_count: jobs.length, jobs }, matrix, run.id);
    if (statePair && jobPair && pairKey(jobPair.requirement, jobPair.environment)
        !== pairKey(statePair.requirement, statePair.environment)) {
      throw new Error(`run ${run.id} disagrees with its persisted dispatcher state`);
    }
    const pair = jobPair ?? statePair;
    if (!pair) {
      throw new Error(`parity workflow run ${run.id} has no trusted matrix pair binding`);
    }
    const artifacts = listAll(
      api,
      `repos/${DISPATCH_POLICY.repository}/actions/runs/${run.id}/artifacts`,
      'artifacts'
    );
    validateArtifacts({ total_count: artifacts.length, artifacts }, context, run, pair);
    records.push({
      runId: run.id,
      runNumber: run.run_number,
      createdAt: run.created_at,
      requirement: pair.requirement,
      environment: pair.environment,
      status: run.status,
      conclusion: run.conclusion,
      candidateBinding: statePair ? 'persisted' : (
        run.status === 'completed' && run.conclusion === 'success' ? 'artifact' : 'unavailable'
      )
    });
  }

  const pairRecords = new Map(matrix.pairs.map((pair) => [pairKey(
    pair.requirement,
    pair.environment
  ), []]));
  for (const record of records) {
    pairRecords.get(pairKey(record.requirement, record.environment)).push(record);
  }

  const completed = [];
  const running = [];
  const queued = [];
  const failed = [];
  const missing = [];
  const plan = [];
  for (const pair of matrix.pairs) {
    const history = pairRecords.get(pairKey(pair.requirement, pair.environment));
    const successes = history.filter((run) => (
      run.status === 'completed' && run.conclusion === 'success'
    ));
    const active = history.filter((run) => ACTIVE_STATUSES.has(run.status));
    const waiting = history.filter((run) => QUEUED_STATUSES.has(run.status));
    if (successes.length > 1) throw new Error(`duplicate successful runs for ${pair.requirement}/${pair.environment}`);
    if (active.length > 1 || waiting.length > 1 || (active.length + waiting.length) > 1) {
      throw new Error(`duplicate active runs for ${pair.requirement}/${pair.environment}`);
    }
    if (successes.length > 0 && active.length + waiting.length > 0) {
      throw new Error(`successful and active runs conflict for ${pair.requirement}/${pair.environment}`);
    }
    if (successes.length === 1) {
      completed.push({ ...pair, runId: successes[0].runId });
      continue;
    }
    if (active.length === 1) {
      running.push({ ...pair, runId: active[0].runId, candidateBinding: active[0].candidateBinding });
      continue;
    }
    if (waiting.length === 1) {
      queued.push({ ...pair, runId: waiting[0].runId, candidateBinding: waiting[0].candidateBinding });
      continue;
    }
    const failures = history.filter((run) => run.status === 'completed' && run.conclusion !== 'success');
    if (failures.length > 0) {
      const latest = [...failures].sort((left, right) => (
        (right.runNumber ?? 0) - (left.runNumber ?? 0)
        || String(right.createdAt ?? '').localeCompare(String(left.createdAt ?? ''))
        || right.runId - left.runId
      ))[0];
      failed.push({ ...pair, runId: latest.runId, conclusion: latest.conclusion ?? 'unknown' });
      plan.push({ ...pair, reason: 'previous-run-failed' });
      continue;
    }
    missing.push(pair);
    plan.push({ ...pair, reason: 'never-dispatched' });
  }

  return {
    records,
    completed: sortedPairs(completed),
    running: sortedPairs(running),
    queued: sortedPairs(queued),
    failed: sortedPairs(failed),
    missing: sortedPairs(missing),
    plan: sortedPairs(plan)
  };
}

function listParityRuns(api, context) {
  return listAll(
    api,
    `repos/${DISPATCH_POLICY.repository}/actions/workflows/${context.workflow.id}/runs`
      + `?event=workflow_dispatch&head_sha=${context.target.sha}`,
    'workflow_runs'
  );
}

function listRunJobs(api, runId) {
  return listAll(
    api,
    `repos/${DISPATCH_POLICY.repository}/actions/runs/${runId}/jobs?filter=latest`,
    'jobs'
  );
}

export async function discoverDispatchedRun({
  api,
  matrix,
  context,
  pending,
  boundRunIds = new Set(),
  pollAttempts,
  pollIntervalMs,
  sleep
}) {
  for (let attempt = 1; attempt <= pollAttempts; attempt += 1) {
    const matches = [];
    for (const runValue of listParityRuns(api, context)) {
      const run = validateRunIdentity(runValue, context);
      if (boundRunIds.has(run.id)) continue;
      const jobs = listRunJobs(api, run.id);
      const pair = parseJobPair({ total_count: jobs.length, jobs }, matrix, run.id);
      if (pair && pairKey(pair.requirement, pair.environment)
          === pairKey(pending.requirement, pending.environment)) {
        matches.push(run);
      }
    }
    if (matches.length > 1) {
      throw new Error(
        `dispatch discovery is ambiguous for ${pending.requirement}/${pending.environment}`
      );
    }
    if (matches.length === 1) return matches[0];
    if (attempt < pollAttempts && pollIntervalMs > 0) await sleep(pollIntervalMs);
  }
  throw new Error(
    `dispatch discovery timed out for ${pending.requirement}/${pending.environment}`
  );
}

function defaultStateFile(repoRoot, context) {
  return path.join(
    repoRoot,
    '.tmp',
    `linux-product-parity-dispatch-${context.target.sha.slice(0, 12)}-${context.candidate.runId}.json`
  );
}

export function createGhApi(spawnSyncImpl = spawnSync) {
  return (endpoint, request = {}) => {
    const args = ['api'];
    let input;
    if (request.method) args.push('--method', request.method);
    args.push(endpoint);
    if (request.body !== undefined) {
      args.push('--input', '-');
      input = JSON.stringify(request.body);
    }
    const result = spawnSyncImpl('gh', args, {
      encoding: 'utf8',
      input,
      maxBuffer: 16 * 1024 * 1024,
      windowsHide: true
    });
    if (result.error?.code === 'ENOENT') throw new Error('GitHub CLI (gh) is required');
    if (result.error) throw new Error(`could not execute gh: ${result.error.message}`);
    if (result.status !== 0) {
      throw new Error(`gh api failed: ${String(result.stderr || result.stdout || 'unknown error').trim()}`);
    }
    if (String(result.stdout ?? '').trim() === '') return undefined;
    try {
      return JSON.parse(result.stdout);
    } catch (error) {
      throw new Error(`gh api returned invalid JSON: ${error.message}`);
    }
  };
}

export async function runDispatcher(options, dependencies = {}) {
  const api = dependencies.api ?? createGhApi();
  const repoRoot = dependencies.repoRoot ?? path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    '..',
    '..'
  );
  const readJson = dependencies.readJson ?? ((file) => JSON.parse(fs.readFileSync(file, 'utf8')));
  const requirementsManifest = dependencies.requirementsManifest
    ?? readJson(path.join(repoRoot, DISPATCH_POLICY.requirementsManifest));
  const evidencePolicies = dependencies.evidencePolicies
    ?? readJson(path.join(repoRoot, DISPATCH_POLICY.evidencePolicies));
  const matrix = validateCanonicalMatrix(requirementsManifest, evidencePolicies);
  const selectedRequirements = selectCanonical(
    options.requirements,
    matrix.requirements,
    '--requirements'
  );
  const selectedEnvironments = selectCanonical(
    options.environments,
    matrix.environments,
    '--environments'
  );
  const selectedPair = (pair) => (
    selectedRequirements.includes(pair.requirement)
      && selectedEnvironments.includes(pair.environment)
  );
  const target = resolveTargetRef(api, options.targetRef);
  const workflow = validateWorkflow(api(
    `repos/${DISPATCH_POLICY.repository}/actions/workflows/linux-product-parity.yml`
  ));
  const candidate = resolveProductEvidenceRun({
    runId: options.candidateRunId,
    targetHead: target.sha
  }, api);
  const context = { target, workflow, candidate };
  const stateFile = path.resolve(options.stateFile ?? defaultStateFile(repoRoot, context));
  const lockIdentityFile = defaultStateFile(repoRoot, context);
  const releaseStateLock = options.execute
    ? (dependencies.acquireStateLock ?? acquireStateLock)(lockIdentityFile, dependencies)
    : () => {};
  try {
    const loadedState = dependencies.state ?? loadState(stateFile, dependencies.readFileSync);
    const stateInfo = validateState(loadedState, context, matrix);
    const persisted = stateInfo.entries;
    const sleep = dependencies.sleep
      ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    const pollAttempts = options.pollAttempts ?? DISPATCH_POLICY.defaultPollAttempts;
    const pollIntervalMs = options.pollIntervalMs ?? DISPATCH_POLICY.defaultPollIntervalMs;
    const boundRunIds = new Set(stateInfo.byRun.keys());
    const recovered = [];

    for (const pending of stateInfo.pending) {
      const run = await discoverDispatchedRun({
        api,
        matrix,
        context,
        pending,
        boundRunIds: new Set([...boundRunIds, ...pending.excludedRunIds]),
        pollAttempts,
        pollIntervalMs,
        sleep
      });
      boundRunIds.add(run.id);
      const entry = {
        ...pending,
        phase: 'bound',
        runId: run.id,
        dispatchedAt: pending.dispatchedAt
          ?? new Date(dependencies.now?.() ?? Date.now()).toISOString()
      };
      persisted.set(pending.nonce, entry);
      recovered.push(entry);
      if (options.execute) {
        writeState(stateFile, stateDocument(context, persisted), dependencies);
      }
    }

    const workingState = stateDocument(context, persisted);
    const status = collectMatrixStatus({ api, matrix, context, state: workingState });
    const observedRunIds = new Set(status.records.map((record) => record.runId));
    const activeCount = status.running.length + status.queued.length;
    const available = Math.max(0, options.maxConcurrency - activeCount);
    const selectedPlan = status.plan.filter(selectedPair);
    const toDispatch = options.execute ? selectedPlan.slice(0, available) : [];
    const dispatched = [];

    if (options.execute) {
      const unbound = [...status.running, ...status.queued]
        .filter((pair) => pair.candidateBinding === 'unavailable');
      if (unbound.length > 0) {
        throw new Error('active runs without persisted candidate binding block safe execution');
      }
      for (const [index, pair] of toDispatch.entries()) {
        const refreshed = resolveTargetRef(api, options.targetRef);
        if (refreshed.sha !== target.sha) {
          throw new Error('target ref moved after planning; no further workflows were dispatched');
        }
        const refreshedCandidate = resolveProductEvidenceRun({
          runId: options.candidateRunId,
          targetHead: target.sha
        }, api);
        if (refreshedCandidate.artifactId !== candidate.artifactId
            || refreshedCandidate.artifactDigest !== candidate.artifactDigest) {
          throw new Error('release candidate evidence changed after planning');
        }
        const dispatchStartedAt = new Date(dependencies.now?.() ?? Date.now()).toISOString();
        const nonce = (dependencies.randomUUID ?? crypto.randomUUID)();
        if (!/^[A-Za-z0-9-]{8,100}$/u.test(nonce) || persisted.has(nonce)) {
          throw new Error('dispatch nonce generator returned an invalid or duplicate nonce');
        }
        const pending = {
          phase: 'pending',
          nonce,
          requirement: pair.requirement,
          environment: pair.environment,
          dispatchStartedAt,
          dispatchedAt: undefined,
          excludedRunIds: [...observedRunIds].sort((left, right) => left - right)
        };
        persisted.set(nonce, pending);
        writeState(stateFile, stateDocument(context, persisted), dependencies);
        const response = api(
          `repos/${DISPATCH_POLICY.repository}/actions/workflows/${workflow.id}/dispatches`,
          {
            method: 'POST',
            body: {
              ref: target.dispatchRef,
              inputs: {
                requirement: pair.requirement,
                environment: pair.environment,
                candidate_run_id: candidate.runId
              }
            }
          }
        );
        const responseRun = response === undefined ? undefined : validateRunIdentity(response, context);
        const run = await discoverDispatchedRun({
          api,
          matrix,
          context,
          pending,
          boundRunIds: new Set([...boundRunIds, ...pending.excludedRunIds]),
          pollAttempts,
          pollIntervalMs,
          sleep
        });
        if (responseRun && responseRun.id !== run.id) {
          throw new Error('workflow dispatch response disagrees with provenance-safe run discovery');
        }
        boundRunIds.add(run.id);
        observedRunIds.add(run.id);
        const entry = {
          ...pending,
          phase: 'bound',
          runId: run.id,
          dispatchedAt: new Date(dependencies.now?.() ?? Date.now()).toISOString()
        };
        persisted.set(nonce, entry);
        dispatched.push(entry);
        writeState(stateFile, stateDocument(context, persisted), dependencies);
        if (index + 1 < toDispatch.length && options.rateLimitMs > 0) {
          await sleep(options.rateLimitMs);
        }
      }
    }
    const finalStatus = options.execute && dispatched.length > 0
      ? collectMatrixStatus({
        api,
        matrix,
        context,
        state: stateDocument(context, persisted)
      })
      : status;
    const finalSelectedPlan = finalStatus.plan.filter(selectedPair);

    return {
      schemaVersion: 1,
      mode: options.execute ? 'execute' : 'dry-run',
      repository: DISPATCH_POLICY.repository,
      workflow,
      target,
      candidate,
      matrix: {
        requirements: matrix.requirements.length,
        environments: matrix.environments.length,
        total: matrix.pairs.length
      },
      selection: {
        requirements: selectedRequirements,
        environments: selectedEnvironments,
        total: selectedRequirements.length * selectedEnvironments.length
      },
      counts: {
        completed: finalStatus.completed.length,
        running: finalStatus.running.length,
        queued: finalStatus.queued.length,
        failed: finalStatus.failed.length,
        missing: finalStatus.missing.length
      },
      status: {
        completed: finalStatus.completed,
        running: finalStatus.running,
        queued: finalStatus.queued,
        failed: finalStatus.failed
      },
      plan: finalSelectedPlan,
      execution: {
        requested: options.execute,
        maxConcurrency: options.maxConcurrency,
        activeAtPlanTime: activeCount,
        capacity: available,
        recovered,
        dispatched,
        remainingAfterPass: finalSelectedPlan.length,
        stateFile
      }
    };
  } finally {
    releaseStateLock();
  }
}

export async function main(argv = process.argv.slice(2), dependencies = {}) {
  const options = parseArguments(argv);
  const result = await runDispatcher(options, dependencies);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`product parity dispatch failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}
