import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

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
  'passed', 'previous', 'previousProvenance', 'schemaVersion', 'steps'
];
const PACKAGE_RECORD_KEYS = ['file', 'sha256', 'size', 'version'];
const PROVENANCE_KEYS = [
  'installedManifest', 'installedManifestSignature', 'packageSignature',
  'productProofClosure', 'productProofClosureSignature', 'releaseCommit', 'releaseTag'
];
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

function validatePackageRecord(record, label, { exactFile = null, prefix = null } = {}) {
  exactKeys(record, PACKAGE_RECORD_KEYS, label);
  const segments = typeof record.file === 'string' ? record.file.split('/') : [];
  if (typeof record.file !== 'string' || record.file.length === 0 || record.file.includes('\\')
      || record.file.startsWith('/') || path.posix.normalize(record.file) !== record.file
      || segments.some((segment) => segment === '.' || segment === '..')
      || !record.file.endsWith('.pkg.tar.zst') || !SHA256.test(record.sha256 ?? '')
      || !Number.isSafeInteger(record.size) || record.size <= 0 || !VERSION.test(record.version ?? '')) {
    throw new Error(`${label} is invalid`);
  }
  if (exactFile !== null && record.file !== exactFile) {
    throw new Error(`${label} path is not release-bound`);
  }
  if (prefix !== null) {
    const basename = record.file.slice(prefix.length);
    if (!record.file.startsWith(prefix) || basename.length === 0 || basename.includes('/')) {
      throw new Error(`${label} path is not confined to ${prefix}`);
    }
  }
  return record;
}

function validateProvenanceRecord(record, label, prefix) {
  exactKeys(record, ['file', 'sha256', 'size'], label);
  const segments = typeof record.file === 'string' ? record.file.split('/') : [];
  if (typeof record.file !== 'string' || record.file.length === 0 || record.file.includes('\\')
      || record.file.startsWith('/') || path.posix.normalize(record.file) !== record.file
      || segments.some((segment) => segment === '.' || segment === '..')
      || !record.file.startsWith(prefix) || record.file.slice(prefix.length).includes('/')
      || !SHA256.test(record.sha256 ?? '') || !Number.isSafeInteger(record.size) || record.size <= 0) {
    throw new Error(`${label} is invalid`);
  }
  return record;
}

function readBoundFile(root, record, label) {
  const relativeFile = record?.file;
  if (typeof relativeFile !== 'string' || relativeFile.length === 0
      || relativeFile.includes('\\') || path.posix.normalize(relativeFile) !== relativeFile
      || path.posix.isAbsolute(relativeFile) || relativeFile.split('/').some((segment) => segment === '.' || segment === '..')) {
    throw new Error(`${label} path is invalid`);
  }
  const absolute = path.resolve(root, relativeFile);
  const relative = path.relative(root, absolute);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes the release root`);
  }
  let current = root;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const metadata = fs.lstatSync(current);
    if (metadata.isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
  const metadata = fs.lstatSync(absolute);
  if (!metadata.isFile()) throw new Error(`${label} is not a regular file`);
  const bytes = fs.readFileSync(absolute);
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  if (bytes.length !== record.size || sha256 !== record.sha256) {
    throw new Error(`${label} bytes do not match the sealed provenance record`);
  }
  return { absolute, bytes };
}

function verifyDetachedEd25519(bytes, signature, publicKey, label) {
  if (signature.length !== 64) throw new Error(`${label} signature must be 64 bytes`);
  let key;
  try {
    key = crypto.createPublicKey(publicKey);
  } catch (error) {
    throw new Error(`release public key is invalid: ${error.message}`);
  }
  if (key.asymmetricKeyType !== 'ed25519' || !crypto.verify(null, bytes, key, signature)) {
    throw new Error(`${label} signature does not verify with the release public key`);
  }
}

/**
 * Re-open and authenticate the Arch lifecycle subjects after all package
 * probes have completed.  The producer performs the native package checks;
 * this second pass makes the finalizer independent of the producer's JSON.
 */
export function authenticateArchLifecycleReport({
  report,
  architecture,
  version,
  gitCommit,
  artifact,
  releaseRoot,
  publicKeyFile,
  candidateSignatureFile
}) {
  validateArchUpdateRollbackReport({ report, architecture, version, gitCommit, artifact });
  if (!releaseRoot || !publicKeyFile || !candidateSignatureFile) {
    throw new Error('Arch lifecycle authentication context is incomplete');
  }
  const root = fs.realpathSync(releaseRoot);
  const publicKey = fs.readFileSync(publicKeyFile);
  const candidate = readBoundFile(root, report.candidate, 'Arch candidate package');
  const candidateSignatureAbsolute = fs.realpathSync(candidateSignatureFile);
  const candidateSignature = readBoundFile(root, {
    file: path.relative(root, candidateSignatureAbsolute).split(path.sep).join('/'),
    size: fs.statSync(candidateSignatureAbsolute).size,
    sha256: crypto.createHash('sha256').update(fs.readFileSync(candidateSignatureAbsolute)).digest('hex')
  }, 'Arch candidate package signature');
  verifyDetachedEd25519(candidate.bytes, candidateSignature.bytes, publicKey, 'Arch candidate package');

  const previous = readBoundFile(root, report.previous, 'Arch previous package');
  const provenance = report.previousProvenance;
  const previousPrefix = `${path.posix.dirname(report.previous.file)}/`;
  const expectedPackageSignature = `${report.previous.file}.ed25519.sig`;
  const expectedManifest = `${previousPrefix}openburnbar-${report.previous.version}-${architecture}.installed-manifest.json`;
  const expectedManifestSignature = `${previousPrefix}openburnbar-${report.previous.version}-${architecture}.installed-manifest.ed25519`;
  const expectedClosure = `${previousPrefix}product-proof-closure.json`;
  const expectedClosureSignature = `${previousPrefix}product-proof-closure.json.ed25519.sig`;
  const exactSubjects = [
    ['package signature', provenance.packageSignature, expectedPackageSignature],
    ['installed manifest', provenance.installedManifest, expectedManifest],
    ['installed manifest signature', provenance.installedManifestSignature, expectedManifestSignature],
    ['product proof closure', provenance.productProofClosure, expectedClosure],
    ['product proof closure signature', provenance.productProofClosureSignature, expectedClosureSignature]
  ];
  const subjects = new Map();
  for (const [label, record, expectedFile] of exactSubjects) {
    if (record.file !== expectedFile) throw new Error(`Arch previous ${label} is not bound to the exact release asset`);
    if (subjects.has(record.file)) throw new Error(`Arch previous provenance subjects are duplicated: ${record.file}`);
    subjects.set(record.file, readBoundFile(root, record, `Arch previous ${label}`));
  }
  const packageSignature = subjects.get(expectedPackageSignature);
  verifyDetachedEd25519(previous.bytes, packageSignature.bytes, publicKey, 'previous Arch package');
  const manifest = subjects.get(expectedManifest);
  const manifestSignature = subjects.get(expectedManifestSignature);
  verifyDetachedEd25519(manifest.bytes, manifestSignature.bytes, publicKey, 'previous Arch installed manifest');
  let manifestDocument;
  let closureDocument;
  try {
    manifestDocument = JSON.parse(manifest.bytes.toString('utf8'));
    closureDocument = JSON.parse(subjects.get(expectedClosure).bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`Arch previous authenticated JSON is invalid: ${error.message}`);
  }
  if (manifestDocument.packageName !== 'openburnbar'
      || manifestDocument.packageFormat !== 'arch'
      || manifestDocument.packageArchitecture !== architecture
      || manifestDocument.packageVersion !== report.previous.version
      || manifestDocument.gitCommit !== provenance.releaseCommit) {
    throw new Error('Arch previous installed manifest identity is not release-bound');
  }
  verifyDetachedEd25519(
    subjects.get(expectedClosure).bytes,
    subjects.get(expectedClosureSignature).bytes,
    publicKey,
    'previous product proof closure'
  );
  if (closureDocument.status !== 'passed' || closureDocument.stage !== 'candidate'
      || closureDocument.version !== report.previous.version
      || closureDocument.targetHead !== provenance.releaseCommit
      || closureDocument.sourceCommit !== provenance.releaseCommit) {
    throw new Error('Arch previous product proof closure identity is not release-bound');
  }
  const packageRows = (closureDocument.packages ?? []).filter((row) =>
    row?.format === 'arch' && row?.architecture === architecture
  );
  if (packageRows.length !== 1) throw new Error('Arch previous product proof closure must contain exactly one matching package row');
  const packageRow = packageRows[0];
  if (packageRow.artifact?.sha256 !== report.previous.sha256 || packageRow.artifact?.size !== report.previous.size
      || packageRow.installedManifest?.sha256 !== provenance.installedManifest.sha256
      || packageRow.installedManifestSignature?.sha256 !== provenance.installedManifestSignature.sha256) {
    throw new Error('Arch previous product proof closure subjects do not match the sealed lifecycle report');
  }
  return true;
}

function previousPackagePrefix(candidateFile) {
  const marker = '/artifacts/';
  const index = candidateFile.lastIndexOf(marker);
  if (index <= 0) throw new Error('Arch candidate package path is not in the release artifact directory');
  return `${candidateFile.slice(0, index)}/previous/arch/`;
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
  const candidate = validatePackageRecord(report.candidate, 'Arch candidate package', {
    exactFile: artifact?.file
  });
  const previous = validatePackageRecord(report.previous, 'Arch previous package', {
    prefix: previousPackagePrefix(candidate.file)
  });
  if (previous.file === candidate.file || previous.sha256 === candidate.sha256
      || compareVersions(previous.version, candidate.version) >= 0) {
    throw new Error('Arch previous package must be a distinct older release');
  }
  exactKeys(report.previousProvenance, PROVENANCE_KEYS, 'Arch previous provenance');
  const provenancePrefix = previousPackagePrefix(candidate.file);
  for (const field of ['packageSignature', 'installedManifest', 'installedManifestSignature', 'productProofClosure']) {
    validateProvenanceRecord(report.previousProvenance[field], `Arch previous ${field}`, provenancePrefix);
  }
  if (report.previousProvenance.releaseTag !== `linux-v${previous.version}`
      || !/^[a-f0-9]{40}$/u.test(report.previousProvenance.releaseCommit ?? '')) {
    throw new Error('Arch previous provenance release identity is invalid');
  }
  if (candidate.file !== artifact?.file || candidate.sha256 !== artifact?.sha256
      || candidate.size !== artifact?.size || candidate.version !== version) {
    throw new Error('Arch candidate package is not bound to the architecture closure artifact');
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
