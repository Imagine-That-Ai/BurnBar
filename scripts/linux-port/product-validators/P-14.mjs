import { P14_PROOF_ROLE, validateP14Proof } from '../lib/p14-chat-proof.mjs';
import { result, validateRequirementContext } from './lib.mjs';

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, ['aggregate-product-proof-closure', P14_PROOF_ROLE]);
  const rows = validated.proofs.get(P14_PROOF_ROLE);
  if (rows.length !== 1) throw new Error('P-14 proof must occur once');
  const proof = validateP14Proof({
    repoRoot: context.repoRoot,
    snapshot: rows[0].snapshot,
    environmentId: context.environmentId,
    targetHead: context.targetHead,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest,
    packageVersion: validated.closure.version,
    manifestSha256: context.subjects.packageManifest.sha256,
    manifestSignatureSha256: validated.closure.packageManifestSignature.sha256
  });
  const evidence = [...validated.artifacts, { path: proof.source.path, sha256: proof.source.sha256 },
    ...proof.evidence.map((item) => ({ path: item.path, sha256: item.sha256 }))];
  return result(context, [...new Map(evidence.map((item) => [item.path, item])).values()]);
}
