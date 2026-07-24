#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  PARITY_PREFLIGHT_FILENAME,
  PARITY_PREFLIGHT_ROLE,
  buildParityCertificationPreflight,
  collectCertificationTestExecutions,
  validateParityCertificationPreflightSchema
} from './lib/parity-certification-preflight.mjs';
import { atomicWriteJson } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

export function parseArguments(argv) {
  const allowed = new Set([
    '--input-root', '--environment', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest', '--diagnostic-root'
  ]);
  const required = new Set([...allowed].filter((flag) => flag !== '--diagnostic-root'));
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || values.has(flag)) {
      throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    }
    values.set(flag, value);
  }
  for (const flag of required) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    inputRoot: values.get('--input-root'),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    diagnosticRoot: values.get('--diagnostic-root')
  };
}

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..'
    && !path.isAbsolute(relative));
}

function trustedTemporaryRoot() {
  return fs.realpathSync(process.env.RUNNER_TEMP ?? os.tmpdir());
}

function validateDiagnosticRoot(requested) {
  const metadata = fs.lstatSync(requested);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new Error('diagnostic root must be a trusted regular directory');
  }
  const root = fs.realpathSync(requested);
  if (!isWithin(trustedTemporaryRoot(), root)) {
    throw new Error('diagnostic root must be inside the trusted runner temporary directory');
  }
  return root;
}

function fallbackDiagnosticRoot() {
  return fs.mkdtempSync(path.join(trustedTemporaryRoot(), 'openburnbar-p02.'));
}

export function captureParityCertificationPreflight(options) {
  const repoRoot = fs.realpathSync(options.repoRoot ?? DEFAULT_REPO_ROOT);
  const requestedInputRoot = typeof options.inputRoot === 'string'
    ? path.resolve(options.inputRoot) : null;
  let diagnosticRoot = null;
  let diagnosticOutput = null;
  try {
    if (options.diagnosticRoot !== undefined) {
      diagnosticRoot = validateDiagnosticRoot(options.diagnosticRoot);
      diagnosticOutput = path.join(diagnosticRoot, 'capture-failure.json');
      fs.rmSync(diagnosticOutput, { recursive: true, force: true });
    }
    if (!requestedInputRoot) throw new Error('input root is required');
    const inputRoot = fs.realpathSync(requestedInputRoot);
    const featureRoot = path.join(inputRoot, 'feature-artifacts');
    const output = path.join(featureRoot, PARITY_PREFLIGHT_FILENAME);
    const registration = path.join(inputRoot, 'feature-proof-registration.json');
    fs.rmSync(output, { force: true });
    fs.rmSync(registration, { force: true });
    const testExecutions = options.testExecutions
      ?? collectCertificationTestExecutions(repoRoot, options.targetHead);
    if (testExecutions.some((entry) => entry.status !== 'passed')) {
      throw new Error('one or more candidate-bound certification ownership tests failed');
    }
    const document = buildParityCertificationPreflight({
      ...options,
      repoRoot,
      inputRoot,
      testExecutions
    });
    validateParityCertificationPreflightSchema(repoRoot, document);
    atomicWriteJson(output, document);
    atomicWriteJson(registration, {
      schemaVersion: 1,
      requirementId: 'P-02',
      environmentId: options.environmentId,
      artifacts: [{
        role: PARITY_PREFLIGHT_ROLE,
        path: `feature-artifacts/${PARITY_PREFLIGHT_FILENAME}`
      }]
    });
    return { document, output, registration };
  } catch (error) {
    if (!diagnosticRoot) diagnosticRoot = fallbackDiagnosticRoot();
    diagnosticOutput = path.join(diagnosticRoot, 'capture-failure.json');
    const diagnostic = {
      schemaVersion: 1,
      id: 'openburnbar-linux-parity-certification-preflight-diagnostic-v1',
      status: 'capture-failed',
      requirementId: 'P-02',
      environmentId: options.environmentId ?? null,
      targetHead: options.targetHead ?? null,
      candidateRunId: options.candidateRunId == null ? null : String(options.candidateRunId),
      candidateArtifactDigest: options.candidateArtifactDigest ?? null,
      error: {
        name: error instanceof Error ? error.name : 'Error',
        message: error instanceof Error ? error.message : String(error)
      }
    };
    try {
      atomicWriteJson(diagnosticOutput, diagnostic);
    } catch {
      diagnosticRoot = fallbackDiagnosticRoot();
      diagnosticOutput = path.join(diagnosticRoot, 'capture-failure.json');
      atomicWriteJson(diagnosticOutput, diagnostic);
    }
    if (error instanceof Error) error.diagnosticOutput = diagnosticOutput;
    throw error;
  }
}

export function main(argv = process.argv.slice(2), repoRoot = DEFAULT_REPO_ROOT) {
  return captureParityCertificationPreflight({ ...parseArguments(argv), repoRoot });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = main();
    process.stdout.write(`${JSON.stringify({
      output: result.output,
      registration: result.registration,
      status: result.document.status,
      summary: result.document.summary
    }, null, 2)}\n`);
  } catch (error) {
    const diagnostic = typeof error?.diagnosticOutput === 'string'
      ? `; diagnostic: ${error.diagnosticOutput}` : '';
    process.stderr.write(`parity certification preflight capture failed: ${error.message}${diagnostic}\n`);
    process.exitCode = 1;
  }
}
