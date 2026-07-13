import { result, validateRequirementContext } from './lib.mjs';
import { P34_PROOF_ROLE, validateP34CredentialSecurityProof } from '../lib/p34-credential-security-proof.mjs';

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure',
    P34_PROOF_ROLE
  ]);
  const rows = validated.proofs.get(P34_PROOF_ROLE);
  if (!Array.isArray(rows) || rows.length !== 1) {
    throw new Error(`${P34_PROOF_ROLE} proof must occur exactly once`);
  }
  validateP34CredentialSecurityProof({
    repoRoot: context.repoRoot,
    snapshot: rows[0].snapshot,
    targetHead: context.targetHead,
    environmentId: context.environmentId,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest
  });
  return result(context, validated.artifacts);
}

