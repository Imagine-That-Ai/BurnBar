export const requiredLifecycleSteps = [
  'guiLaunch',
  'daemonLaunch',
  'versionReadback',
  'update',
  'rollback',
  'dataPreservation'
];

export function validateArchitectureSessionSet({ manifest, sessions, version, commit }) {
  const failures = [];
  const seen = new Set();
  for (const session of sessions) {
    const architecture = session?.architecture;
    if (session?.schemaVersion !== 1) failures.push(`architecture session has invalid schema: ${architecture ?? 'unknown'}`);
    if (!manifest.supportedArchitectures.includes(architecture)) failures.push(`architecture session is unsupported: ${architecture ?? 'unknown'}`);
    if (seen.has(architecture)) failures.push(`duplicate architecture session: ${architecture}`);
    seen.add(architecture);
    if (session?.version !== version) failures.push(`architecture session version does not match: ${architecture}`);
    if (session?.gitCommit !== commit) failures.push(`architecture session commit does not match: ${architecture}`);
    for (const step of requiredLifecycleSteps) {
      if (session?.lifecycle?.[step]?.status !== 'passed') {
        failures.push(`architecture session ${architecture ?? 'unknown'} lifecycle is not passed: ${step}`);
      }
    }
    if (session?.passed !== true) failures.push(`architecture session is not green: ${architecture ?? 'unknown'}`);
  }
  for (const architecture of manifest.supportedArchitectures) {
    if (!seen.has(architecture)) failures.push(`missing architecture session: ${architecture}`);
  }
  if (sessions.length !== manifest.supportedArchitectures.length) {
    failures.push('architecture session set has missing or extra entries');
  }
  return [...new Set(failures)];
}

export function aggregateArchitectureLifecycle({ manifest, sessions }) {
  const lifecycle = {};
  for (const step of requiredLifecycleSteps) {
    const blocked = manifest.supportedArchitectures.flatMap((architecture) => {
      const session = sessions.find((candidate) => candidate.architecture === architecture);
      const row = session?.lifecycle?.[step];
      return row?.status === 'passed'
        ? []
        : [{ architecture, reason: row?.reason ?? 'Architecture session evidence is missing.' }];
    });
    lifecycle[step] = blocked.length === 0
      ? { status: 'passed', architectures: [...manifest.supportedArchitectures] }
      : { status: 'blocked', blockers: blocked };
  }
  const failedCount = Object.values(lifecycle).filter((row) => row.status !== 'passed').length;
  return { lifecycle, failedCount, passed: failedCount === 0 };
}
