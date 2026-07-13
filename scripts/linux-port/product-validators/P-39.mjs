import {
  P39_PROOF_ROLE,
  parseP39Json,
  validateP39DifferentialProof
} from '../lib/p39-differential-proof.mjs';
import { result, validateRequirementContext } from './lib.mjs';

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure',
    'feature-proof-closure',
    'feature-proof-registry',
    P39_PROOF_ROLE
  ]);
  const rows = validated.proofs.get(P39_PROOF_ROLE);
  if (!Array.isArray(rows) || rows.length !== 1
      || rows[0].evidenceClass !== 'feature' || rows[0].mediaType !== 'application/json') {
    throw new Error('P-39 differential proof must occur exactly once as registered JSON feature evidence');
  }
  validateP39DifferentialProof({
    repoRoot: context.repoRoot,
    snapshot: rows[0].snapshot,
    targetHead: context.targetHead,
    environmentId: context.environmentId,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest,
    releaseVersion: validated.closure.version
  });
  // Parse once through the same source to make the substantive result explicit.
  const document = parseP39Json(rows[0].snapshot.bytes, 'P-39 differential proof');
  if (document.status !== 'passed' || document.comparison.mismatchCount !== 0) {
    throw new Error('P-39 differential proof is not a passed zero-mismatch comparison');
  }
  return result(context, validated.artifacts);
}
