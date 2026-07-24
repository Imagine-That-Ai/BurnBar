import {
  P39_PROOF_ROLE,
  validateP39DifferentialProof
} from '../lib/p39-differential-proof.mjs';
import { result, validateRequirementContext } from './lib.mjs';

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure',
    P39_PROOF_ROLE
  ]);
  const rows = validated.proofs.get(P39_PROOF_ROLE);
  if (!Array.isArray(rows) || rows.length !== 1) {
    throw new Error(`${P39_PROOF_ROLE} proof must occur exactly once`);
  }
  const proof = validateP39DifferentialProof({
    repoRoot: context.repoRoot,
    snapshot: rows[0].snapshot,
    targetHead: context.targetHead,
    environmentId: context.environmentId,
    version: validated.closure.version,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest
  });
  return result(context, [
    ...validated.artifacts,
    proof.macos,
    proof.linux,
    proof.report
  ]);
}
