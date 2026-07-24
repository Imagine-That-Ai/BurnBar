import {
  P08_PROOF_ROLE,
  validateP08MercuryMediaProof
} from '../lib/p08-mercury-media-proof.mjs';
import { readRegularSnapshot } from '../lib/product-proof-closure.mjs';
import { result, validateRequirementContext } from './lib.mjs';

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure',
    P08_PROOF_ROLE
  ]);
  const proofs = validated.proofs.get(P08_PROOF_ROLE);
  if (!Array.isArray(proofs) || proofs.length !== 1) {
    throw new Error(`${P08_PROOF_ROLE} proof must occur exactly once`);
  }
  const feature = context.subjects.features ?? [];
  if (feature.length !== 1 || feature[0].role !== P08_PROOF_ROLE || feature[0].mediaType !== 'application/json') {
    throw new Error(`P-08 feature proof role must occur exactly once as ${P08_PROOF_ROLE}`);
  }
  const proofSnapshot = readRegularSnapshot(context.repoRoot, feature[0].path, 'P-08 Mercury media feature proof');
  if (proofSnapshot.sha256 !== feature[0].sha256 || proofSnapshot.sha256 !== proofs[0].snapshot.sha256) {
    throw new Error('P-08 Mercury media feature proof bytes changed');
  }
  validateP08MercuryMediaProof({
    repoRoot: context.repoRoot,
    snapshot: proofSnapshot,
    environmentId: context.environmentId,
    targetHead: context.targetHead,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest
  });
  return result(context, validated.artifacts);
}
