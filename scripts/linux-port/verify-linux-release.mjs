#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  manifestPath,
  readJson,
  relative,
  releaseEvidenceDir,
  repoRoot,
  runStep,
  sha256,
  writeJson
} from './lib/linux-release-common.mjs';
import { verifyLinuxReleaseCandidate } from './lib/linux-release-verify.mjs';
import { deriveReleaseAttestationSubjects } from './lib/product-proof-closure.mjs';

const argv = process.argv.slice(2);
const phaseIndex = argv.indexOf('--phase');
const versionIndex = argv.indexOf('--version');
const phase = phaseIndex >= 0 ? argv[phaseIndex + 1] : 'pre-attestation';
const requestedVersion = versionIndex >= 0 ? argv[versionIndex + 1] : null;
const diagnostic = argv.includes('--diagnostic') || argv.includes('--allow-blocked');
const candidate = argv.includes('--candidate');
const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? releaseEvidenceDir);
const manifest = readJson(manifestPath);
const failures = [];
const warnings = [];
const fail = (message, detail = {}) => failures.push({ message, ...detail });

if (argv.includes('--allow-blocked')) {
  warnings.push({ message: '--allow-blocked is deprecated; diagnostic output never downgrades release failures.' });
}

function safeReadJson(file, label) {
  if (!fs.existsSync(file)) {
    fail(`${label} is missing.`, { file: relative(file) });
    return {};
  }
  try {
    return readJson(file);
  } catch (error) {
    fail(`${label} is not valid JSON.`, { file: relative(file), error: String(error) });
    return {};
  }
}

const closurePath = path.join(outDir, 'package-closure.json');
const closure = safeReadJson(closurePath, 'package closure');
const latestPath = path.join(outDir, manifest.updateMetadata.draftName);
const latest = safeReadJson(latestPath, 'latest-linux draft');
const provenanceRecord = closure.sidecars?.provenancePredicate;
const provenanceRel = typeof provenanceRecord === 'string' ? provenanceRecord : provenanceRecord?.file;
const provenance = provenanceRel
  ? safeReadJson(path.join(repoRoot, provenanceRel), 'provenance predicate')
  : (fail('provenance predicate is absent from the package closure.'), {});
const smokeSummary = safeReadJson(
  path.join(outDir, 'smoke/package-smoke-summary.json'),
  'package smoke summary'
);
const publicKeyPath = path.join(repoRoot, manifest.signing.publicKey);
const publicKeyPem = fs.existsSync(publicKeyPath) ? fs.readFileSync(publicKeyPath, 'utf8') : '';
if (!publicKeyPem) fail('pinned Linux release public key is missing.', { file: manifest.signing.publicKey });

const headStep = runStep('git', ['rev-parse', 'HEAD']);
const expectedHead = process.env.OPENBURNBAR_GIT_COMMIT?.trim() || headStep.stdout.trim();
if (headStep.exitCode !== 0 && !process.env.OPENBURNBAR_GIT_COMMIT) fail('release verifier cannot determine target git HEAD.');
const expectedVersion = requestedVersion?.trim() || closure.version;

const pure = verifyLinuxReleaseCandidate({
  repoRoot,
  manifest,
  closure,
  provenance,
  latest,
  smokeSummary,
  publicKeyPem,
  expectedHead,
  expectedVersion,
  phase,
  requireParity: !candidate
});
failures.push(...pure.failures);

for (const [kind, relPath] of Object.entries(manifest.tailMetadata ?? {})) {
  const full = path.resolve(repoRoot, relPath);
  if (!full.startsWith(`${repoRoot}${path.sep}`) || !fs.existsSync(full)) {
    fail(`${kind} release metadata is missing or outside the repository.`, { file: relPath });
  }
}

const sourceRecord = closure.sidecars?.sourceArchive;
const sourceRel = typeof sourceRecord === 'string' ? sourceRecord : sourceRecord?.file;
if (sourceRel && expectedHead && expectedVersion) {
  const sourcePath = path.join(repoRoot, sourceRel);
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-source-verify-'));
  const expectedArchive = path.join(tempDir, 'expected.tar');
  const archive = runStep('git', [
    'archive',
    '--format=tar',
    `--prefix=OpenBurnBar-${expectedVersion}/`,
    `--output=${expectedArchive}`,
    expectedHead
  ]);
  if (archive.exitCode !== 0) {
    fail('failed to regenerate the release source archive from target HEAD.', { stderr: archive.stderr });
  } else if (!fs.existsSync(sourcePath) || sha256(expectedArchive) !== sha256(sourcePath)) {
    fail('source archive does not equal a fresh git archive of the release commit.');
  }
  fs.rmSync(tempDir, { recursive: true, force: true });
}

if (!candidate) {
  const ledger = runStep('node', ['scripts/linux-port/validate-parity-ledger.mjs'], {
    cwd: repoRoot,
    env: process.env
  });
  if (ledger.exitCode !== 0) {
    fail('parity ledger is not green for release promotion.', {
      command: ledger.command,
      stdout: ledger.stdout,
      stderr: ledger.stderr
    });
  }
}

if (phase === 'final' && closure.artifacts) {
  const identity = manifest.signing.cosignIdentityTemplate.replace('{version}', expectedVersion);
  let attestationSubjects = [];
  try {
    attestationSubjects = deriveReleaseAttestationSubjects(closure, manifest.requiredArtifacts);
  } catch (error) {
    fail('Exact Linux release attestation subject set is invalid.', { error: error.message });
  }
  for (const subject of attestationSubjects) {
    const subjectFile = subject.record.file ?? subject.record.path;
    const bundle = `${subjectFile}.sigstore.json`;
    if (!fs.existsSync(path.join(repoRoot, bundle))) {
      fail('Sigstore bundle is missing for a required release subject.', { artifact: subjectFile, bundle });
      continue;
    }
    const verification = runStep('cosign', [
      'verify-blob-attestation',
      '--bundle',
      path.join(repoRoot, bundle),
      '--type',
      'https://openburnbar.dev/attestations/linux-release-artifact/v1',
      '--certificate-identity',
      identity,
      '--certificate-oidc-issuer',
      manifest.signing.cosignIssuer,
      path.join(repoRoot, subjectFile)
    ]);
    if (verification.exitCode !== 0) {
      fail('Sigstore bundle verification failed.', {
        artifact: subjectFile,
        stderr: verification.stderr
      });
    }
  }
}

const gitStatus = runStep('git', ['status', '--porcelain=v1']).stdout.split('\n').filter(Boolean);
const outRelative = relative(outDir);
const generatedPrefixes = [
  outRelative,
  process.env.OPENBURNBAR_LINUX_SHARDS_DIR
    ? relative(path.resolve(process.env.OPENBURNBAR_LINUX_SHARDS_DIR))
    : null,
  process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT
    ? relative(path.resolve(process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT))
    : null
].filter((value) => value && !value.startsWith('..'));
const unexpectedDirty = gitStatus.filter((entry) => {
  const dirtyPath = entry.slice(3);
  return !generatedPrefixes.some((prefix) => dirtyPath.startsWith(`${prefix.replace(/\/$/, '')}/`));
});
if (unexpectedDirty.length > 0) {
  fail('release checkout has unexpected dirty files outside generated release output.', {
    dirtyEntries: unexpectedDirty.slice(0, 40)
  });
}

const report = {
  generatedAt: new Date().toISOString(),
  phase,
  diagnostic,
  outDir: relative(outDir),
  expectedHead,
  expectedVersion,
  passed: failures.length === 0,
  failures,
  warnings
};
fs.mkdirSync(outDir, { recursive: true });
writeJson(path.join(outDir, 'release-verification.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(report.passed ? 0 : 1);
