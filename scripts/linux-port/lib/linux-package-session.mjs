export const requiredLifecycleSteps = [
  'guiLaunch',
  'daemonLaunch',
  'versionReadback',
  'update',
  'rollback',
  'dataPreservation'
];

const ARCH_LIFECYCLE_KEYS = [
  'architecture', 'candidate', 'gitCommit', 'lifecycle', 'manager', 'packageName',
  'passed', 'previous', 'schemaVersion', 'steps'
];
const PACKAGE_RECORD_KEYS = ['file', 'sha256', 'size', 'version'];
const TRANSITION_KEYS = [
  'architecture', 'fromSha256', 'fromVersion', 'manager', 'packageName', 'status',
  'toSha256', 'toVersion'
];
const DATA_PRESERVATION_KEYS = [
  'afterPreviousSha256', 'afterRestoreSha256', 'afterRollbackSha256',
  'afterUpdateSha256', 'sentinelSha256', 'status'
];
const SHA256 = /^[a-f0-9]{64}$/u;
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;

function exactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(`${label} fields are not exact`);
  }
}

function validatePackageRecord(record, label) {
  exactKeys(record, PACKAGE_RECORD_KEYS, label);
  if (typeof record.file !== 'string' || record.file.length === 0 || record.file.includes('\\')
      || record.file.startsWith('/') || record.file === '..' || record.file.startsWith('../')
      || !record.file.endsWith('.pkg.tar.zst') || !SHA256.test(record.sha256 ?? '')
      || !Number.isSafeInteger(record.size) || record.size <= 0 || !VERSION.test(record.version ?? '')) {
    throw new Error(`${label} is invalid`);
  }
  return record;
}

function compareVersions(left, right) {
  const leftParts = left.split('.').map(Number);
  const rightParts = right.split('.').map(Number);
  for (let index = 0; index < leftParts.length; index += 1) {
    if (leftParts[index] !== rightParts[index]) return leftParts[index] - rightParts[index];
  }
  return 0;
}

function validateTransition(row, expected, label) {
  exactKeys(row, TRANSITION_KEYS, label);
  for (const [key, value] of Object.entries(expected)) {
    if (row[key] !== value) throw new Error(`${label} ${key} is not release-bound`);
  }
}

function validateArchLifecycleSteps(steps, previous, candidate) {
  const expectedPackages = [previous, candidate, previous, candidate];
  if (!Array.isArray(steps) || steps.length !== 18 || steps.some((step) => step?.exitCode !== 0)) {
    throw new Error('Arch update/rollback report does not contain the exact successful command sequence');
  }
  if (!steps[0].command?.startsWith('pacman -Syu --noconfirm --needed ')
      || !steps[1].command?.startsWith('pacman -T ')) {
    throw new Error('Arch update/rollback dependency preparation is not pacman-bound');
  }
  for (const [index, record] of expectedPackages.entries()) {
    const offset = 2 + (index * 4);
    if (steps[offset].command !== `pacman -U --noconfirm /workspace/${record.file}`
        || steps[offset + 1].command !== 'pacman -Qi openburnbar'
        || steps[offset + 2].command !== '/usr/bin/openburnbar-linux-desktop --version'
        || steps[offset + 3].command !== '/usr/libexec/openburnbar-daemon-launch --help') {
      throw new Error('Arch update/rollback command sequence is not bound to pacman and the exact packages');
    }
  }
}

export function validateArchUpdateRollbackReport({ report, architecture, version, gitCommit, artifact }) {
  exactKeys(report, ARCH_LIFECYCLE_KEYS, 'Arch update/rollback report');
  if (report.schemaVersion !== 1 || report.passed !== true || report.manager !== 'pacman'
      || report.packageName !== 'openburnbar' || report.architecture !== architecture
      || report.gitCommit !== gitCommit) {
    throw new Error('Arch update/rollback report is not a passed pacman lifecycle for this architecture and commit');
  }
  const candidate = validatePackageRecord(report.candidate, 'Arch candidate package');
  const previous = validatePackageRecord(report.previous, 'Arch previous package');
  if (candidate.file !== artifact?.file || candidate.sha256 !== artifact?.sha256
      || candidate.size !== artifact?.size || candidate.version !== version) {
    throw new Error('Arch candidate package is not bound to the architecture closure artifact');
  }
  if (previous.file === candidate.file || previous.sha256 === candidate.sha256
      || compareVersions(previous.version, candidate.version) >= 0) {
    throw new Error('Arch previous package must be a distinct older release');
  }
  validateArchLifecycleSteps(report.steps, previous, candidate);
  exactKeys(report.lifecycle, ['dataPreservation', 'rollback', 'update'], 'Arch lifecycle');
  const shared = { status: 'passed', manager: 'pacman', packageName: 'openburnbar', architecture };
  validateTransition(report.lifecycle.update, {
    ...shared,
    fromVersion: previous.version,
    toVersion: candidate.version,
    fromSha256: previous.sha256,
    toSha256: candidate.sha256
  }, 'Arch update');
  validateTransition(report.lifecycle.rollback, {
    ...shared,
    fromVersion: candidate.version,
    toVersion: previous.version,
    fromSha256: candidate.sha256,
    toSha256: previous.sha256
  }, 'Arch rollback');
  const preservation = report.lifecycle.dataPreservation;
  exactKeys(preservation, DATA_PRESERVATION_KEYS, 'Arch data preservation');
  if (preservation.status !== 'passed' || !SHA256.test(preservation.sentinelSha256 ?? '')
      || ['afterPreviousSha256', 'afterUpdateSha256', 'afterRollbackSha256', 'afterRestoreSha256']
        .some((field) => preservation[field] !== preservation.sentinelSha256)) {
    throw new Error('Arch data-preservation proof is invalid');
  }
  return report.lifecycle;
}

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
