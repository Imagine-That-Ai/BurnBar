#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { repoRoot } from './lib/linux-release-common.mjs';
import {
  attestProductRequirement,
  removeStaleProductRequirementOutput
} from './lib/product-requirement-attestation.mjs';

export function parseAttestationArguments(argv) {
  const parsed = { requirementId: null, validatorReceiptPaths: [], artifactPaths: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (!['--requirement', '--validator-receipt', '--artifact'].includes(flag)) {
      throw new Error(`unknown argument: ${flag}`);
    }
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) throw new Error(`${flag} requires a value`);
    index += 1;
    if (flag === '--requirement') {
      if (parsed.requirementId !== null) throw new Error('--requirement may be specified only once');
      parsed.requirementId = value;
    } else if (flag === '--validator-receipt') {
      parsed.validatorReceiptPaths.push(value);
    } else {
      parsed.artifactPaths.push(value);
    }
  }
  if (parsed.requirementId === null) throw new Error('--requirement is required');
  return parsed;
}

function requirementHint(argv) {
  const index = argv.indexOf('--requirement');
  return index >= 0 ? argv[index + 1] : null;
}

export function main(argv = process.argv.slice(2), root = repoRoot) {
  let requirementId = requirementHint(argv);
  try {
    const parsed = parseAttestationArguments(argv);
    requirementId = parsed.requirementId;
    const result = attestProductRequirement({ repoRoot: root, ...parsed });
    process.stdout.write(`${JSON.stringify(result.attestation, null, 2)}\n`);
    return result;
  } catch (error) {
    try { removeStaleProductRequirementOutput(root, requirementId); } catch (cleanupError) {
      process.stderr.write(`cleanup failed: ${cleanupError.message}\n`);
    }
    throw error;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`product requirement attestation failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
