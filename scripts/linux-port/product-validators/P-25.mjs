import { P25_PROOF_ROLE, validateP25Proof } from "../lib/p25-updates-proof.mjs";
import {
  aggregateArchitectureLifecycle,
  requiredLifecycleSteps,
  validateArchitectureSessionSet,
} from "../lib/linux-package-session.mjs";
import {
  requirePassedJsonProof,
  result,
  validateRequirementContext,
} from "./lib.mjs";

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    "aggregate-product-proof-closure",
    "architecture-sessions",
    "package-smoke",
    P25_PROOF_ROLE,
  ]);
  const sessions = requirePassedJsonProof(
    validated.proofs.get("architecture-sessions"),
    "architecture-sessions",
  );
  const smoke = requirePassedJsonProof(
    validated.proofs.get("package-smoke"),
    "package-smoke",
  );
  const sessionFailures = validateArchitectureSessionSet({
    manifest: { supportedArchitectures: validated.closure.architectures },
    sessions: sessions.sessions ?? [],
    version: validated.closure.version,
    commit: context.targetHead,
  });
  const aggregate = aggregateArchitectureLifecycle({
    manifest: { supportedArchitectures: validated.closure.architectures },
    sessions: sessions.sessions ?? [],
  });
  const lifecyclePassed = requiredLifecycleSteps.every(
    (step) =>
      smoke.lifecycle?.[step]?.status === "passed" &&
      validated.closure.architectures.every((architecture) =>
        smoke.lifecycle[step].architectures?.includes(architecture),
      ) &&
      aggregate.lifecycle[step].status === "passed",
  );
  if (sessionFailures.length > 0 || !lifecyclePassed)
    throw new Error(
      "P-25 requires real update, rollback, restore, and data-preservation lifecycle proof for both release architectures",
    );
  const rows = validated.proofs.get(P25_PROOF_ROLE);
  if (!Array.isArray(rows) || rows.length !== 1)
    throw new Error(`${P25_PROOF_ROLE} proof must occur exactly once`);
  const proof = validateP25Proof({
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
  const selectedSession = (sessions.sessions ?? []).find(
    (session) => session.architecture === proof.lifecycleBinding.architecture,
  );
  if (
    selectedSession?.lifecycle?.update?.status !== "passed" ||
    selectedSession.lifecycle.update.fromVersion !==
      proof.lifecycleBinding.previousVersion ||
    selectedSession.lifecycle.update.toVersion !==
      proof.lifecycleBinding.candidateVersion ||
    selectedSession.lifecycle.rollback?.status !== "passed" ||
    selectedSession.lifecycle.rollback.fromVersion !==
      proof.lifecycleBinding.candidateVersion ||
    selectedSession.lifecycle.rollback.toVersion !==
      proof.lifecycleBinding.previousVersion ||
    selectedSession.lifecycle.dataPreservation?.status !== "passed" ||
    !smoke.lifecycle.update.architectures.includes(
      proof.lifecycleBinding.architecture,
    ) ||
    !smoke.lifecycle.rollback.architectures.includes(
      proof.lifecycleBinding.architecture,
    ) ||
    !smoke.lifecycle.dataPreservation.architectures.includes(
      proof.lifecycleBinding.architecture,
    )
  )
    throw new Error(
      "P-25 installed lifecycle does not match architecture-session and package-smoke receipts",
    );
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
