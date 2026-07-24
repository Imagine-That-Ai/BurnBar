import crypto from 'node:crypto';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const COMMIT_DIGEST_PATTERN = /^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$/u;
const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
const REPOSITORY_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;
const WORKFLOW_PATTERN = /^(?:github\.com\/)?[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/\.github\/workflows\/[A-Za-z0-9_.\/-]+\.ya?ml$/u;
const SOURCE_REF_PATTERN = /^refs\/[A-Za-z0-9._\/-]+$/u;

function requireString(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value.trim() !== value) {
    throw new Error(`${label} must be a nonempty string without surrounding whitespace`);
  }
  return value;
}

function requireFileArgument(value, label) {
  const result = requireString(value, label);
  if (result.startsWith('-') || result.includes('\0')) {
    throw new Error(`${label} is not a safe gh file argument`);
  }
  return result;
}

function validatedSignerWorkflow(value) {
  const workflow = requireString(value, 'signerWorkflow');
  if (!WORKFLOW_PATTERN.test(workflow) || workflow.includes('..')) {
    throw new Error('signerWorkflow must be an exact GitHub Actions workflow path');
  }
  return workflow;
}

function signerWorkflowUrl(value) {
  const workflow = validatedSignerWorkflow(value);
  const path = workflow.startsWith('github.com/') ? workflow.slice('github.com/'.length) : workflow;
  return `https://github.com/${path}`;
}

function certificateWorkflowMatches(value, expectedWorkflowUrl) {
  return typeof value === 'string'
    && value.startsWith(`${expectedWorkflowUrl}@`)
    && value.length > expectedWorkflowUrl.length + 1;
}

function parseVerificationOutput(stdout) {
  let parsed;
  try {
    parsed = JSON.parse(String(stdout ?? ''));
  } catch (error) {
    throw new Error(`gh attestation verify returned malformed JSON: ${error.message}`);
  }
  if (!Array.isArray(parsed) || parsed.length === 0) {
    throw new Error('gh attestation verify returned no verified attestations');
  }
  return parsed;
}

function validateVerificationResult(entry, index, expected) {
  const result = entry?.verificationResult;
  if (result === null || typeof result !== 'object' || Array.isArray(result)) {
    throw new Error(`verified attestation ${index + 1} is missing verificationResult`);
  }

  const subjects = result.statement?.subject;
  if (!Array.isArray(subjects) || subjects.length === 0) {
    throw new Error(`verified attestation ${index + 1} is missing statement subjects`);
  }
  const hasReceiptSubject = subjects.some((subject) => {
    const digest = subject?.digest?.sha256;
    return typeof digest === 'string'
      && SHA256_PATTERN.test(digest)
      && digest === expected.receiptSha256;
  });
  if (!hasReceiptSubject) {
    throw new Error(`verified attestation ${index + 1} does not bind the receipt SHA-256 digest`);
  }

  const certificate = result.signature?.certificate;
  if (certificate === null || typeof certificate !== 'object' || Array.isArray(certificate)) {
    throw new Error(`verified attestation ${index + 1} is missing the verified certificate summary`);
  }
  if (certificate.sourceRepositoryURI !== expected.sourceRepositoryURI) {
    throw new Error(`verified attestation ${index + 1} has the wrong source repository identity`);
  }
  if (certificate.sourceRepositoryDigest?.toLowerCase() !== expected.sourceDigest) {
    throw new Error(`verified attestation ${index + 1} has the wrong source repository digest`);
  }
  if (certificate.sourceRepositoryRef !== expected.sourceRef) {
    throw new Error(`verified attestation ${index + 1} has the wrong source repository ref`);
  }
  if (!certificateWorkflowMatches(certificate.subjectAlternativeName, expected.signerWorkflowUrl)) {
    throw new Error(`verified attestation ${index + 1} has the wrong signer workflow identity`);
  }
  if (certificate.buildSignerURI !== undefined
      && !certificateWorkflowMatches(certificate.buildSignerURI, expected.signerWorkflowUrl)) {
    throw new Error(`verified attestation ${index + 1} has the wrong build signer identity`);
  }

  return {
    subjectAlternativeName: certificate.subjectAlternativeName,
    sourceRepositoryURI: certificate.sourceRepositoryURI,
    sourceRepositoryDigest: certificate.sourceRepositoryDigest.toLowerCase(),
    sourceRepositoryRef: certificate.sourceRepositoryRef
  };
}

export function buildGitHubArtifactVerificationArgs({
  receiptPath,
  repository,
  bundlePath,
  signerWorkflow,
  sourceDigest,
  sourceRef
}) {
  const receipt = requireFileArgument(receiptPath, 'receiptPath');
  const bundle = requireFileArgument(bundlePath, 'bundlePath');
  const repo = requireString(repository, 'repository');
  if (!REPOSITORY_PATTERN.test(repo)) {
    throw new Error('repository must be an exact owner/repository name');
  }
  const workflow = validatedSignerWorkflow(signerWorkflow);
  const digest = requireString(sourceDigest, 'sourceDigest');
  if (!COMMIT_DIGEST_PATTERN.test(digest)) {
    throw new Error('sourceDigest must be an exact 40- or 64-character hexadecimal commit digest');
  }
  const ref = requireString(sourceRef, 'sourceRef');
  if (!SOURCE_REF_PATTERN.test(ref) || ref.includes('..') || ref.includes('//')) {
    throw new Error('sourceRef must be an exact canonical refs/... value');
  }

  return [
    'attestation',
    'verify',
    receipt,
    '--repo',
    repo,
    '--bundle',
    bundle,
    '--signer-workflow',
    workflow,
    '--source-digest',
    digest,
    '--source-ref',
    ref,
    '--format',
    'json'
  ];
}

export function verifyGitHubArtifactProvenance(options, dependencies = {}) {
  const args = buildGitHubArtifactVerificationArgs(options);
  const readFileSyncImpl = dependencies.readFileSync ?? fs.readFileSync;
  const spawnSyncImpl = dependencies.spawnSync ?? spawnSync;

  let receiptBytes;
  try {
    receiptBytes = readFileSyncImpl(options.receiptPath);
  } catch (error) {
    throw new Error(`could not read receipt for provenance verification: ${error.message}`);
  }
  const receiptSha256 = crypto.createHash('sha256').update(receiptBytes).digest('hex');

  const execution = spawnSyncImpl('gh', args, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    windowsHide: true
  });
  if (execution?.error) {
    const reason = execution.error.code === 'ENOENT'
      ? 'GitHub CLI (gh) is not installed or not available on PATH'
      : execution.error.message;
    throw new Error(`could not execute gh attestation verify: ${reason}`);
  }
  if (!Number.isInteger(execution?.status) || execution.status !== 0) {
    const detail = String(execution?.stderr || execution?.stdout || 'unknown gh failure').trim();
    throw new Error(`gh attestation verify failed: ${detail}`);
  }

  const verified = parseVerificationOutput(execution.stdout);
  const expected = {
    receiptSha256,
    sourceRepositoryURI: `https://github.com/${options.repository}`,
    sourceDigest: options.sourceDigest.toLowerCase(),
    sourceRef: options.sourceRef,
    signerWorkflowUrl: signerWorkflowUrl(options.signerWorkflow)
  };
  const certificates = verified.map((entry, index) => validateVerificationResult(entry, index, expected));

  return {
    receiptSha256,
    verifiedAttestationCount: verified.length,
    certificates
  };
}
