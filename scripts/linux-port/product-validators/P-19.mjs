import {
  P19_PROOF_ROLE,
  validateP19Proof,
} from "../lib/p19-projects-proof.mjs";
import { result, validateRequirementContext } from "./lib.mjs";

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    "aggregate-product-proof-closure",
    P19_PROOF_ROLE,
  ]);
  const rows = validated.proofs.get(P19_PROOF_ROLE);
  if (!Array.isArray(rows) || rows.length !== 1)
    throw new Error(`${P19_PROOF_ROLE} proof must occur exactly once`);
  const proof = validateP19Proof({
    repoRoot: context.repoRoot,
    snapshot: rows[0].snapshot,
    environmentId: context.environmentId,
    targetHead: context.targetHead,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest,
    packageVersion: validated.closure.version,
    manifestSha256: context.subjects.packageManifest.sha256,
    manifestSignatureSha256: validated.closure.packageManifestSignature.sha256,
  });
  const artifacts = [
    ...validated.artifacts,
    { path: proof.source.path, sha256: proof.source.sha256 },
    ...proof.evidence.map((record) => ({
      path: record.path,
      sha256: record.sha256,
    })),
  ];
  return result(context, [
    ...new Map(artifacts.map((record) => [record.path, record])).values(),
  ]);
}
