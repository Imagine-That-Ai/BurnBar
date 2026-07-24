import { requirePassedJsonProof, result, validateRequirementContext } from './lib.mjs';
import {
  aggregateArchitectureLifecycle,
  requiredLifecycleSteps,
  validateArchitectureSessionSet
} from '../lib/linux-package-session.mjs';

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure', 'architecture-sessions', 'package-smoke'
  ]);
  const sessions = requirePassedJsonProof(validated.proofs.get('architecture-sessions'), 'architecture-sessions');
  const smoke = requirePassedJsonProof(validated.proofs.get('package-smoke'), 'package-smoke');
  const sessionFailures = validateArchitectureSessionSet({
    manifest: { supportedArchitectures: validated.closure.architectures },
    sessions: sessions.sessions ?? [],
    version: validated.closure.version,
    commit: context.targetHead
  });
  const aggregate = aggregateArchitectureLifecycle({
    manifest: { supportedArchitectures: validated.closure.architectures },
    sessions: sessions.sessions ?? []
  });
  const smokeArchitectures = Array.isArray(smoke.architectures) ? smoke.architectures : [];
  const exactArchitectures = smokeArchitectures.length === validated.closure.architectures.length
    && new Set(smokeArchitectures).size === validated.closure.architectures.length
    && validated.closure.architectures.every((architecture) => smokeArchitectures.includes(architecture));
  const lifecyclePassed = requiredLifecycleSteps.every((step) =>
    smoke.lifecycle?.[step]?.status === 'passed'
      && Array.isArray(smoke.lifecycle[step].architectures)
      && smoke.lifecycle[step].architectures.length === validated.closure.architectures.length
      && validated.closure.architectures.every((architecture) => smoke.lifecycle[step].architectures.includes(architecture))
      && aggregate.lifecycle[step].status === 'passed'
  );
  if (sessionFailures.length > 0 || !exactArchitectures || !lifecyclePassed) {
    throw new Error('installed lifecycle proof must cover both release architectures');
  }
  if (validated.runtime.daemonProtocolVersion !== validated.manifest.brokerProtocolVersion) {
    throw new Error('live daemon protocol does not match the signed installed manifest');
  }
  return result(context, validated.artifacts);
}
