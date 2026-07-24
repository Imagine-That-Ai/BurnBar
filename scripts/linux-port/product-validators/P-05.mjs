import { result, validateRequirementContext } from './lib.mjs';
import { P05_PROOF_ROLE, validateP05CredentialCustodyProof } from '../lib/p05-credential-custody-proof.mjs';
import { readRegularSnapshot } from '../lib/product-proof-closure.mjs';

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure',
    P05_PROOF_ROLE
  ]);
  const rows = validated.proofs.get(P05_PROOF_ROLE);
  if (!Array.isArray(rows) || rows.length !== 1) throw new Error(`${P05_PROOF_ROLE} proof must occur exactly once`);
  const proof = validateP05CredentialCustodyProof({
    repoRoot: context.repoRoot,
    snapshot: rows[0].snapshot,
    targetHead: context.targetHead,
    environmentId: context.environmentId,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest
  });
  const requirementRoot = `docs/linux-port/evidence/product-parity-inputs/${context.requirementId}/`;
  if (!proof.source.path.startsWith(requirementRoot)) throw new Error('P-05 session source is outside the requirement evidence root');
  const sourceSnapshot = readRegularSnapshot(context.repoRoot, proof.source.path, 'P-05 installed custody session source');
  if (sourceSnapshot.sha256 !== proof.source.sha256) throw new Error('P-05 installed custody session source bytes changed');
  validateP05CredentialCustodyProof({
    repoRoot: context.repoRoot,
    snapshot: rows[0].snapshot,
    sourceSnapshot,
    targetHead: context.targetHead,
    environmentId: context.environmentId,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest
  });
  return result(context, validated.artifacts);
}
