#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { captureP39Differential } from './lib/p39-differential-proof.mjs';

export { captureP39Differential };

const DEFAULT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function parseArgs(argv) {
  const allowed = new Set([
    '--input-root', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest'
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

function main() {
  const args = parseArgs(process.argv.slice(2));
  const result = captureP39Differential({
    repoRoot: DEFAULT_ROOT,
    inputRoot: path.resolve(args.inputRoot),
    environmentId: args.environmentId,
    targetHead: args.targetHead,
    candidateRunId: args.candidateRunId,
    candidateArtifactDigest: args.candidateArtifactDigest
  });
  process.stdout.write(`${JSON.stringify({
    output: path.relative(DEFAULT_ROOT, result.output),
    registration: path.relative(DEFAULT_ROOT, result.registration),
    status: result.document.status
  }, null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`P-39 differential capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
