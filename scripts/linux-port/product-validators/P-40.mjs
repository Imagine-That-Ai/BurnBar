import {
  P40_PROOF_ROLE,
  validateP40DataPrivacyProof
} from '../lib/p40-data-privacy-proof.mjs';
import { result, validateRequirementContext } from './lib.mjs';

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure',
    'feature-proof-closure',
    'feature-proof-registry',
    P40_PROOF_ROLE
  ]);
  const rows = validated.proofs.get(P40_PROOF_ROLE);
  if (!Array.isArray(rows) || rows.length !== 1
      || rows[0].evidenceClass !== 'feature' || rows[0].mediaType !== 'application/json') {
    throw new Error('P-40 data privacy proof must occur exactly once as registered JSON feature evidence');
  }
  validateP40DataPrivacyProof({
    repoRoot: context.repoRoot,
    snapshot: rows[0].snapshot,
    targetHead: context.targetHead,
    environmentId: context.environmentId,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest
  });
  return result(context, validated.artifacts);
}

