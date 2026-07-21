export function createEnvironmentCoverageReport(input) {
  const blocked = input.checks
    .filter((check) => !check.passed)
    .map((check) => ({
      capability: check.id,
      status: 'blocked',
      platformReason: check.detail,
      recordedAt: input.generatedAt
    }));
  const artifacts = [input.installedEvidence, input.accessibilityEvidence]
    .filter((evidence) => evidence?.passed === true && evidence.commit === input.git.commit)
    .map(({ path, sha256 }) => ({ path, sha256 }))
    .sort((left, right) => left.path.localeCompare(right.path));

  return {
    schemaVersion: 1,
    generatedAt: input.generatedAt,
    environmentId: input.environmentId,
    targetHead: input.git.commit,
    status: blocked.length === 0 ? 'passed' : 'blocked',
    artifacts,
    git: input.git,
    declared: input.declared,
    detected: input.detected,
    evidenceInputs: {
      installedEvidence: input.installedEvidence,
      accessibilityEvidence: input.accessibilityEvidence
    },
    checks: input.checks,
    blocked,
    note: 'Passed means this exact clean checkout produced current-HEAD, hash-bound installed-package and accessibility evidence on the declared live desktop.'
  };
}
