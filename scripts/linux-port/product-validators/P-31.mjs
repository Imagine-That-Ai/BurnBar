import {
  P31_ROLES,
  parseP31Json,
  validateP31Proof
} from '../lib/p31-accessibility-proof.mjs';
import {
  readRegularSnapshot
} from '../lib/product-proof-closure.mjs';
import {
  requirePassedJsonProof,
  result,
  validateRequirementContext
} from './lib.mjs';

function featureProofs(context) {
  const features = context.subjects.features ?? [];
  if (features.length !== P31_ROLES.length) {
    throw new Error(`P-31 requires exactly ${P31_ROLES.length} feature proofs`);
  }
  const byRole = new Map();
  for (const feature of features) {
    if (!P31_ROLES.includes(feature.role) || byRole.has(feature.role)) {
      throw new Error(`P-31 feature proof roles are not exactly: ${P31_ROLES.join(', ')}`);
    }
    const snapshot = readRegularSnapshot(context.repoRoot, feature.path, `${feature.role} feature proof`);
    if (snapshot.sha256 !== feature.sha256) throw new Error(`${feature.role} feature proof bytes changed`);
    byRole.set(feature.role, parseP31Json(snapshot.bytes, `${feature.role} feature proof`));
  }
  if (P31_ROLES.some((role) => !byRole.has(role))) {
    throw new Error(`P-31 feature proof roles are not exactly: ${P31_ROLES.join(', ')}`);
  }
  return byRole;
}

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, ['aggregate-product-proof-closure']);
  requirePassedJsonProof(validated.proofs.get('aggregate-product-proof-closure'), 'aggregate-product-proof-closure');
  const proofs = featureProofs(context);
  for (const role of P31_ROLES) {
    validateP31Proof(proofs.get(role), {
      role,
      environmentId: context.environmentId,
      targetHead: context.targetHead,
      candidateRunId: context.releaseClosure.document.candidate.runId,
      candidateArtifactDigest: context.releaseClosure.document.candidate.artifactDigest
    });
  }
  return result(context, validated.artifacts);
}
