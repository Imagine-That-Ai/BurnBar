import {
  PARITY_PREFLIGHT_ROLE,
  parseParityCertificationPreflight,
  validateParityCertificationPreflight
} from '../lib/parity-certification-preflight.mjs';
import { result, validateRequirementContext } from './lib.mjs';

const REQUIRED = [
  'aggregate-product-proof-closure',
  'feature-proof-closure',
  'feature-proof-registry',
  PARITY_PREFLIGHT_ROLE
];

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, REQUIRED);
  const rows = validated.proofs.get(PARITY_PREFLIGHT_ROLE);
  if (rows?.length !== 1 || rows[0].evidenceClass !== 'feature'
      || rows[0].mediaType !== 'application/json') {
    throw new Error('parity certification preflight proof must occur exactly once as registered JSON feature evidence');
  }
  const document = parseParityCertificationPreflight(rows[0].snapshot);
  validateParityCertificationPreflight(document, {
    repoRoot: context.repoRoot,
    targetHead: context.targetHead,
    environmentId: context.environmentId,
    materializedProofPath: rows[0].path,
    candidate: validated.closure.candidate
  });
  if (document.status !== 'passed' || document.blockers.length !== 0
      || document.summary.requirementCount !== 40
      || document.summary.policyCount !== 40
      || document.summary.environmentCount !== 7
      || document.summary.validatorCount !== 40
      || document.summary.captureCount !== 40
      || document.summary.materializerCount !== 40
      || document.summary.readyCount !== 40
      || document.summary.blockerCount !== 0
      || document.requirements.some((row) => row.ready !== true)) {
    throw new Error('parity certification preflight remains blocked by incomplete substantive parity coverage');
  }
  return result(context, validated.artifacts);
}
