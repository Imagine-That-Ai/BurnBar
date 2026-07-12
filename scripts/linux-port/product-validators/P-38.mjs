import {
  aggregateArchitectureLifecycle,
  requiredLifecycleSteps,
  validateArchitectureSessionSet
} from '../lib/linux-package-session.mjs';
import { validateP38ReleaseAutomationProof } from '../lib/p38-release-automation-proof.mjs';
import { requirePassedJsonProof, result, validateRequirementContext } from './lib.mjs';

const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;

function exactMatrix(rows, role, architectures, formats) {
  const expected = formats.flatMap((format) => architectures.map((architecture) => `${format}:${architecture}`));
  const keys = rows.map((row) => `${row.format}:${row.architecture}`);
  if (rows.length !== expected.length || new Set(keys).size !== expected.length
      || expected.some((key) => !keys.includes(key))) {
    throw new Error(`${role} proof must cover every release format and architecture exactly once`);
  }
}

function compareVersions(left, right) {
  const leftParts = left.split('.').map(Number);
  const rightParts = right.split('.').map(Number);
  for (let index = 0; index < leftParts.length; index += 1) {
    if (leftParts[index] !== rightParts[index]) return leftParts[index] - rightParts[index];
  }
  return 0;
}

function transitionVersions(session) {
  const update = session.lifecycle?.update;
  const rollback = session.lifecycle?.rollback;
  const previous = update?.fromVersion ?? update?.from;
  const candidate = update?.toVersion ?? update?.to;
  const rollbackFrom = rollback?.fromVersion ?? rollback?.from;
  const rollbackTo = rollback?.toVersion ?? rollback?.to;
  if (!VERSION.test(previous ?? '') || !VERSION.test(candidate ?? '')
      || compareVersions(previous, candidate) >= 0 || candidate !== session.version
      || rollbackFrom !== candidate || rollbackTo !== previous) {
    throw new Error(`architecture session has no exact older-release update/rollback transition: ${session.architecture}`);
  }
}

function validateLifecycle(sessions, smoke, architectures, version, targetHead) {
  const failures = validateArchitectureSessionSet({
    manifest: { supportedArchitectures: architectures },
    sessions,
    version,
    commit: targetHead
  });
  if (failures.length > 0) throw new Error(`architecture sessions are not complete: ${failures.join('; ')}`);
  const aggregate = aggregateArchitectureLifecycle({
    manifest: { supportedArchitectures: architectures },
    sessions
  });
  const smokeArchitectures = smoke.architectures ?? [];
  if (smokeArchitectures.length !== architectures.length || new Set(smokeArchitectures).size !== architectures.length
      || architectures.some((architecture) => !smokeArchitectures.includes(architecture))) {
    throw new Error('package smoke does not cover both release architectures exactly once');
  }
  for (const session of sessions) {
    if (session.packageSmokePassed !== true || !Array.isArray(session.blockers) || session.blockers.length !== 0) {
      throw new Error(`architecture session contains package blockers: ${session.architecture}`);
    }
    transitionVersions(session);
    if (session.lifecycle?.dataPreservation?.status !== 'passed') {
      throw new Error(`architecture session has no data-preservation proof: ${session.architecture}`);
    }
  }
  for (const step of requiredLifecycleSteps) {
    const row = smoke.lifecycle?.[step];
    if (row?.status !== 'passed' || aggregate.lifecycle[step]?.status !== 'passed'
        || !Array.isArray(row.architectures) || row.architectures.length !== architectures.length
        || architectures.some((architecture) => !row.architectures.includes(architecture))) {
      throw new Error(`package lifecycle is not passed for both architectures: ${step}`);
    }
  }
}

function validateProvenance(rows, architectures, version, targetHead) {
  if (!Array.isArray(rows) || rows.length !== 1) throw new Error('provenance proof must occur exactly once');
  let provenance;
  try {
    provenance = JSON.parse(rows[0].snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`provenance proof is not valid JSON: ${error.message}`);
  }
  const provenanceArchitectures = (provenance.architectures ?? []).map((row) => row?.architecture);
  if (provenance.git?.commit !== targetHead || provenance.git?.dirty !== false || provenance.version !== version
      || provenanceArchitectures.length !== architectures.length
      || new Set(provenanceArchitectures).size !== architectures.length
      || architectures.some((architecture) => !provenanceArchitectures.includes(architecture))) {
    throw new Error('release provenance is not bound to the clean two-architecture candidate');
  }
}

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, [
    'aggregate-product-proof-closure',
    'architecture-sessions',
    'package-signature',
    'package-sigstore',
    'package-smoke',
    'provenance',
    'workflow-verification'
  ]);
  const architectures = validated.closure.architectures;
  exactMatrix(validated.proofs.get('package-signature'), 'package-signature', architectures, [
    'appimage', 'arch', 'daemon', 'deb', 'rpm'
  ]);
  exactMatrix(validated.proofs.get('package-sigstore'), 'package-sigstore', architectures, [
    'appimage', 'arch', 'daemon', 'deb', 'rpm'
  ]);
  if (validated.proofs.get('package-signature').some((row) => row.snapshot.size !== 64)
      || validated.proofs.get('package-sigstore').some((row) => row.snapshot.size <= 0)) {
    throw new Error('release signing proof is missing or malformed');
  }
  const sessions = requirePassedJsonProof(validated.proofs.get('architecture-sessions'), 'architecture-sessions');
  const smoke = requirePassedJsonProof(validated.proofs.get('package-smoke'), 'package-smoke');
  validateLifecycle(sessions.sessions ?? [], smoke, architectures, validated.closure.version, context.targetHead);
  validateProvenance(validated.proofs.get('provenance'), architectures, validated.closure.version, context.targetHead);
  const workflowRows = validated.proofs.get('workflow-verification');
  if (workflowRows.length !== 1) throw new Error('workflow-verification proof must occur exactly once');
  validateP38ReleaseAutomationProof({
    repoRoot: context.repoRoot,
    snapshot: workflowRows[0].snapshot,
    targetHead: context.targetHead,
    environmentId: context.environmentId,
    candidateRunId: validated.closure.candidate.runId,
    candidateArtifactDigest: validated.closure.candidate.artifactDigest
  });
  return result(context, validated.artifacts);
}
