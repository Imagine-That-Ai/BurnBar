#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { finalizeProductFeatureProofClosure } from './lib/product-feature-proof.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

export function parseArguments(argv) {
  const allowed = new Set([
    '--requirement', '--environment', '--input-root', '--target-head',
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
  if (!/^[a-f0-9]{40,64}$/u.test(values.get('--target-head'))) {
    throw new Error('--target-head must be a commit id');
  }
  return {
    requirementId: values.get('--requirement'),
    environmentId: values.get('--environment'),
    inputRoot: values.get('--input-root'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    repoRoot: DEFAULT_REPO_ROOT
  };
}

export function main(argv = process.argv.slice(2), repoRoot = DEFAULT_REPO_ROOT) {
  return finalizeProductFeatureProofClosure({ ...parseArguments(argv), repoRoot });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = main();
    process.stdout.write(`${JSON.stringify({
      registered: result.registered,
      output: result.output,
      status: result.closure?.status ?? 'not-registered'
    }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`product feature proof closure finalization failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
