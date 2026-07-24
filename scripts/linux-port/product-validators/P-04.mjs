import { requirePassedJsonProof, result, validateRequirementContext } from './lib.mjs';

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure', 'architecture-sessions', 'architecture-smoke'
  ]);
  const sessions = requirePassedJsonProof(validated.proofs.get('architecture-sessions'), 'architecture-sessions');
  const smoke = requirePassedJsonProof(validated.proofs.get('architecture-smoke'), 'architecture-smoke');
  const sessionArchitectures = new Set((sessions.sessions ?? []).map((entry) => entry.architecture));
  const smokeArchitectures = new Set((smoke.architectures ?? []).map((entry) => entry.architecture));
  for (const architecture of validated.closure.architectures) {
    if (!sessionArchitectures.has(architecture) || !smokeArchitectures.has(architecture)) {
      throw new Error(`architecture proof does not cover ${architecture}`);
    }
  }
  return result(context, validated.artifacts);
}
