import { result, validateRequirementContext } from "./lib.mjs";
import { P15_PROOF_ROLE, validateP15Proof } from "../lib/p15-account-billing-proof.mjs";
export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, ["aggregate-product-proof-closure", P15_PROOF_ROLE]); const rows = validated.proofs.get(P15_PROOF_ROLE); if (!Array.isArray(rows) || rows.length !== 1) throw new Error(`${P15_PROOF_ROLE} proof must occur exactly once`);
  const proof = validateP15Proof({ repoRoot: context.repoRoot, snapshot: rows[0].snapshot, targetHead: context.targetHead, environmentId: context.environmentId, candidateRunId: validated.closure.candidate.runId, candidateArtifactDigest: validated.closure.candidate.artifactDigest, packageVersion: validated.closure.version, manifestSha256: context.subjects.packageManifest.sha256, manifestSignatureSha256: validated.closure.packageManifestSignature.sha256 });
  const artifacts = [...validated.artifacts, { path: proof.source.path, sha256: proof.source.sha256 }, ...proof.evidence.map((record) => ({ path: record.path, sha256: record.sha256 }))]; return result(context, [...new Map(artifacts.map((record) => [record.path, record])).values()]);
}
