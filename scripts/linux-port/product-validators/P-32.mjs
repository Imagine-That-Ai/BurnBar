import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  P32_PROOF_ROLE,
  validateP32Proof,
} from "../lib/p32-performance-proof.mjs";
import { result, validateRequirementContext } from "./lib.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    "aggregate-product-proof-closure",
    P32_PROOF_ROLE,
  ]);
  const rows = validated.proofs.get(P32_PROOF_ROLE);
  if (!Array.isArray(rows) || rows.length !== 1)
    throw new Error(`${P32_PROOF_ROLE} proof must occur exactly once`);
  const proof = validateP32Proof({
    repoRoot: context.repoRoot,
    snapshot: rows[0].snapshot,
    environmentId: context.environmentId,
    targetHead: context.targetHead,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest,
    packageVersion: validated.closure.version,
    manifestSha256: context.subjects.packageManifest.sha256,
    manifestSignatureSha256: validated.closure.packageManifestSignature.sha256,
    budget: JSON.parse(
      fs.readFileSync(
        path.join(context.repoRoot ?? ROOT, "budgets/linux-desktop.perf.json"),
        "utf8",
      ),
    ),
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
