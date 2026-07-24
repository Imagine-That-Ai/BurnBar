import { requirePassedJsonProof, result, validateRequirementContext } from './lib.mjs';

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure', 'architecture-smoke'
  ]);
  requirePassedJsonProof(validated.proofs.get('architecture-smoke'), 'architecture-smoke');
  if (!validated.closure.supportEnvironments.includes(context.environmentId)) {
    throw new Error('live environment is outside the canonical Linux support matrix');
  }
  return result(context, validated.artifacts);
}
