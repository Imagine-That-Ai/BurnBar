#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  PARITY_PREFLIGHT_FILENAME,
  PARITY_PREFLIGHT_ROLE,
  buildParityCertificationPreflight,
  validateParityCertificationPreflightSchema
} from './lib/parity-certification-preflight.mjs';
import { atomicWriteJson } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

export function parseArguments(argv) {
  const allowed = new Set([
    '--input-root', '--environment', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || values.has(flag)) {
      throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    }
    values.set(flag, value);
  }
  for (const flag of allowed) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    inputRoot: values.get('--input-root'),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest')
  };
}

export function captureParityCertificationPreflight(options) {
  const repoRoot = fs.realpathSync(options.repoRoot ?? DEFAULT_REPO_ROOT);
  const inputRoot = fs.realpathSync(options.inputRoot);
  const featureRoot = path.join(inputRoot, 'feature-artifacts');
  const output = path.join(featureRoot, PARITY_PREFLIGHT_FILENAME);
  const registration = path.join(inputRoot, 'feature-proof-registration.json');
  fs.rmSync(output, { force: true });
  fs.rmSync(registration, { force: true });
  const document = buildParityCertificationPreflight({ ...options, repoRoot, inputRoot });
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
    process.stderr.write(`parity certification preflight capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
