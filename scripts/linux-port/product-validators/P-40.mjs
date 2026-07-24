import {
  P40_PROOF_ROLE,
  validateP40PrivacyProof,
  validateP40LiveSession,
  parseP40Json
} from '../lib/p40-privacy-proof.mjs';
import { readRegularSnapshot } from '../lib/product-proof-closure.mjs';
import { result, validateRequirementContext } from './lib.mjs';

function validateSourceBinding(context, proof) {
  const root = `docs/linux-port/evidence/product-parity-inputs/${context.requirementId}`;
  if (typeof proof.source?.path !== 'string' || !proof.source.path.startsWith(`${root}/`)) {
    throw new Error('P-40 proof source must remain under the requirement evidence root');
  }
  const source = readRegularSnapshot(context.repoRoot, proof.source.path, 'P-40 live session source');
  if (source.sha256 !== proof.source.sha256) throw new Error('P-40 live session source bytes changed');
  const session = parseP40Json(source.bytes, 'P-40 live session source');
  validateP40LiveSession(session, {
    environmentId: context.environmentId,
    targetHead: context.targetHead,
    candidateRunId: context.releaseClosure.document.candidate.runId,
    candidateArtifactDigest: context.releaseClosure.document.candidate.artifactDigest
  });
  const projection = {
    candidate: proof.candidate,
    capture: proof.capture,
    contract: proof.contract,
    daemon: proof.daemon,
    desktop: proof.desktop,
    environmentId: proof.environmentId,
    id: 'openburnbar-linux-p40-live-session-v1',
    observations: proof.observations,
    package: proof.package,
    requirementId: proof.requirementId,
    schemaVersion: proof.schemaVersion,
    targetHead: proof.targetHead
  };
  if (JSON.stringify(projection) !== JSON.stringify(session)) {
    throw new Error('P-40 proof claim does not match the live session source');
  }
}

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure',
    P40_PROOF_ROLE
  ]);
  const rows = validated.proofs.get(P40_PROOF_ROLE);
  if (!Array.isArray(rows) || rows.length !== 1) throw new Error(`${P40_PROOF_ROLE} proof must occur exactly once`);
  const proof = validateP40PrivacyProof({
    repoRoot: context.repoRoot,
    snapshot: rows[0].snapshot,
    targetHead: context.targetHead,
    environmentId: context.environmentId,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest
  });
  validateSourceBinding(context, proof);
  return result(context, validated.artifacts);
}
