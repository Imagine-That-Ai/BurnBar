#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {
  expectedLinuxReleaseIdentity,
  manifestPath,
  readJson,
  relative,
  releaseEvidenceDir,
  repoRoot,
  runStep,
  sha256,
  verifyEd25519Signature,
  writeJson
} from './lib/linux-release-common.mjs';

const args = new Set(process.argv.slice(2));
const allowBlocked = args.has('--allow-blocked');
const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? releaseEvidenceDir);
const manifest = readJson(manifestPath);
const failures = [];
const warnings = [];

function fail(message, detail = {}) {
  failures.push({ message, ...detail });
}

function warn(message, detail = {}) {
  warnings.push({ message, ...detail });
}

function requireFile(relPath, label) {
  const full = path.join(repoRoot, relPath);
  if (!fs.existsSync(full)) {
    fail(`${label} is missing`, { file: relPath });
    return false;
  }
  return true;
}

const closurePath = path.join(outDir, 'package-closure.json');
const latestPath = path.join(outDir, manifest.updateMetadata.draftName);
if (!fs.existsSync(closurePath)) fail('package-closure.json is missing; run build-linux-release first.');
if (!fs.existsSync(latestPath)) fail(`${manifest.updateMetadata.draftName} is missing; run build-linux-release first.`);

const closure = fs.existsSync(closurePath) ? readJson(closurePath) : { artifacts: [], blockers: [] };
const latest = fs.existsSync(latestPath) ? readJson(latestPath) : { blockers: [] };
const provenancePath = path.join(repoRoot, closure.sidecars?.provenancePredicate ?? '');
const provenance = readJsonOrNull(provenancePath);

const release = closure.release;
if (!release?.tag || !release?.ref || !release?.commit || !release?.expectedCosignIdentity) {
  fail('package closure lacks a complete tag-bound release identity.');
} else {
  let canonicalIdentity = null;
  try {
    canonicalIdentity = expectedLinuxReleaseIdentity(release.ref);
  } catch (error) {
    fail('release ref is not a valid Linux release tag ref.', { detail: String(error) });
  }
  if (release.tag !== `linux-v${closure.version}` || release.ref !== `refs/tags/${release.tag}`) {
    fail('release tag, ref, and package version disagree.', { release, version: closure.version });
  }
  if (canonicalIdentity && release.expectedCosignIdentity !== canonicalIdentity) {
    fail('expected Cosign identity is not derived from the release tag ref.', {
      expected: canonicalIdentity,
      actual: release.expectedCosignIdentity
    });
  }
  if (closure.git?.commit !== release.commit || latest.commit !== release.commit) {
    fail('release metadata is not bound to one commit.', {
      releaseCommit: release.commit,
      closureCommit: closure.git?.commit ?? null,
      latestCommit: latest.commit ?? null
    });
  }
  if (JSON.stringify(latest.release) !== JSON.stringify(release)
      || JSON.stringify(provenance?.release) !== JSON.stringify(release)) {
    fail('release identity drifted across package closure, latest metadata, and provenance predicate.');
  }

  const head = runStep('git', ['rev-parse', 'HEAD']);
  const tag = runStep('git', ['rev-list', '-n', '1', `${release.ref}^{commit}`]);
  if (head.exitCode !== 0 || head.stdout.trim() !== release.commit) {
    fail('release checkout HEAD does not equal the recorded release commit.', {
      expected: release.commit,
      actual: head.stdout.trim() || null
    });
  }
  if (tag.exitCode !== 0 || tag.stdout.trim() !== release.commit) {
    fail('release tag does not resolve to the recorded release commit.', {
      ref: release.ref,
      expected: release.commit,
      actual: tag.stdout.trim() || null
    });
  }

  const expectedEnvironment = {
    tag: process.env.OPENBURNBAR_RELEASE_TAG,
    ref: process.env.OPENBURNBAR_RELEASE_REF,
    commit: process.env.OPENBURNBAR_RELEASE_COMMIT,
    expectedCosignIdentity: process.env.OPENBURNBAR_EXPECTED_COSIGN_IDENTITY
  };
  if (Object.values(expectedEnvironment).some(Boolean)
      && Object.entries(expectedEnvironment).some(([key, value]) => value !== release[key])) {
    fail('release metadata disagrees with the workflow-resolved release identity.', {
      expected: expectedEnvironment,
      actual: release
    });
  }
}

for (const required of manifest.requiredArtifacts) {
  const artifact = closure.artifacts?.find((row) => row.type === required);
  if (!artifact) {
    fail(`Required ${required} artifact is absent from package closure.`);
    continue;
  }
  if (!requireFile(artifact.file, `${required} artifact`)) continue;
  const actual = sha256(path.join(repoRoot, artifact.file));
  if (actual !== artifact.sha256) {
    fail(`${required} artifact checksum drifted`, { file: artifact.file, expected: artifact.sha256, actual });
  }
}

for (const [kind, relPath] of Object.entries(manifest.tailMetadata)) {
  if (!requireFile(relPath, `${kind} metadata`)) continue;
  if (kind === 'desktopEntry') {
    const desktopFile = fs.readFileSync(path.join(repoRoot, relPath), 'utf8');
    if (!desktopFile.includes('Type=Application') || !desktopFile.includes('Exec=')) {
      fail('desktop entry lacks Type=Application or Exec=', { file: relPath });
    }
  }
}

const checksumRel = closure.sidecars?.checksums;
if (checksumRel && requireFile(checksumRel, 'checksums sidecar')) {
  const lines = fs.readFileSync(path.join(repoRoot, checksumRel), 'utf8').split('\n').filter(Boolean);
  for (const line of lines) {
    const match = line.match(/^([a-f0-9]{64})  (.+)$/);
    if (!match) {
      fail('checksum sidecar contains an invalid line', { line });
      continue;
    }
    const [, expected, file] = match;
    if (!requireFile(file, 'checksum target')) continue;
    const actual = sha256(path.join(repoRoot, file));
    if (actual !== expected) fail('checksum sidecar mismatch', { file, expected, actual });
  }
} else {
  fail('checksums sidecar is missing from package closure.');
}

for (const sidecar of ['sbom', 'vex', 'provenancePredicate']) {
  const relPath = closure.sidecars?.[sidecar];
  if (!relPath) {
    fail(`${sidecar} sidecar is missing from package closure.`);
  } else {
    requireFile(relPath, `${sidecar} sidecar`);
  }
}

const signatures = provenance?.signatures ?? [];
if (!signatures.length) {
  fail('No Ed25519/minisign-compatible detached signatures are recorded.');
} else {
  const requiredArtifactFiles = manifest.requiredArtifacts
    .map((type) => closure.artifacts?.find((artifact) => artifact.type === type)?.file)
    .filter(Boolean);
  const publicKeyRel = manifest.externalCredentials?.ed25519PublicKey;
  let publicKeyPem = null;
  if (!publicKeyRel || !requireFile(publicKeyRel, 'Ed25519 release public key')) {
    fail('Ed25519 release public key is not configured in the release manifest.');
  } else {
    publicKeyPem = fs.readFileSync(path.join(repoRoot, publicKeyRel));
  }
  if (signatures.length !== requiredArtifactFiles.length) {
    fail('Detached signature inventory does not exactly cover required artifacts.', {
      required: requiredArtifactFiles.length,
      recorded: signatures.length
    });
  }
  for (const artifactFile of requiredArtifactFiles) {
    const rows = signatures.filter((row) => row.artifact === artifactFile);
    if (rows.length !== 1) {
      fail('Required artifact must have exactly one detached signature.', {
        artifact: artifactFile,
        recorded: rows.length
      });
      continue;
    }
    const row = rows[0];
    if (row.algorithm !== 'Ed25519' || !requireFile(row.signature, 'Ed25519 detached signature')) {
      fail('Required artifact signature metadata is invalid.', { artifact: artifactFile });
      continue;
    }
    if (publicKeyPem && !verifyEd25519Signature(
      fs.readFileSync(path.join(repoRoot, artifactFile)),
      fs.readFileSync(path.join(repoRoot, row.signature)),
      publicKeyPem
    )) {
      fail('Detached signature does not verify with the checked-in release public key.', {
        artifact: artifactFile,
        signature: row.signature
      });
    }
  }
}
if (provenance?.expectedCosignIdentity !== release?.expectedCosignIdentity) {
  fail('provenance predicate Cosign identity differs from the release identity.');
}

const sourceArchive = closure.sidecars?.sourceArchive;
if (!sourceArchive?.file || !sourceArchive?.sha256 || !sourceArchive?.checksumFile || !sourceArchive?.represents) {
  fail('source archive binding is missing from package closure.');
} else if (requireFile(sourceArchive.file, 'source archive')) {
  const actual = sha256(path.join(repoRoot, sourceArchive.file));
  if (actual !== sourceArchive.sha256) {
    fail('source archive checksum drifted.', { file: sourceArchive.file, expected: sourceArchive.sha256, actual });
  }
  if (requireFile(sourceArchive.checksumFile, 'source archive checksum')) {
    const checksum = fs.readFileSync(path.join(repoRoot, sourceArchive.checksumFile), 'utf8').trim();
    if (!checksum.startsWith(`${sourceArchive.sha256}  `)) {
      fail('source archive checksum sidecar does not match the archive.', {
        file: sourceArchive.checksumFile,
        expected: sourceArchive.sha256
      });
    }
  }
  if (sourceArchive.represents !== release?.commit
      || provenance?.sourceArchive?.represents !== release?.commit
      || latest.sidecars?.sourceArchive?.represents !== release?.commit) {
    fail('source archive does not represent the exact release commit.', {
      expected: release?.commit ?? null,
      closure: sourceArchive.represents,
      provenance: provenance?.sourceArchive?.represents ?? null,
      latest: latest.sidecars?.sourceArchive?.represents ?? null
    });
  }
  if (release?.commit && !path.basename(sourceArchive.file).includes(release.commit.slice(0, 12))) {
    fail('source archive filename does not carry the release commit prefix.', { file: sourceArchive.file });
  }
}

if (!latest.primaryArtifact || latest.promotionState !== 'candidate') {
  fail('latest-linux draft is not promotable.', {
    promotionState: latest.promotionState ?? null,
    primaryArtifact: latest.primaryArtifact ?? null
  });
}

const publicLatest = path.join(repoRoot, 'website/public/downloads/latest-linux.json');
if (fs.existsSync(publicLatest)) {
  if (failures.length > 0 || latest.promotionState !== 'candidate') {
    fail('public latest-linux.json exists while release verification is not green.', {
      file: relative(publicLatest)
    });
  }
} else {
  warn('public latest-linux.json is absent, as expected until promotion is green.');
}

const smokeDir = path.join(outDir, 'smoke');
for (const smoke of ['package-install-uninstall.log', 'package-update-rollback.log']) {
  if (!fs.existsSync(path.join(smokeDir, smoke))) {
    fail('required package smoke log is missing', { file: relative(path.join(smokeDir, smoke)) });
  }
}

const gitStatus = runStep('git', ['status', '--porcelain=v1']).stdout.split('\n').filter(Boolean);
const unexpectedDirty = gitStatus.filter((entry) => {
  const path = entry.slice(3);
  return !path.startsWith(relative(outDir) + '/');
});
if (unexpectedDirty.length > 0) {
  fail('release checkout has unexpected dirty files outside generated Linux release evidence.', {
    dirtyEntries: unexpectedDirty.slice(0, 40)
  });
}

const ledger = runStep('node', ['scripts/linux-port/validate-parity-ledger.mjs'], { cwd: repoRoot });
if (ledger.exitCode !== 0) {
  fail('parity ledger is not green for release promotion.', {
    command: ledger.command,
    stdout: ledger.stdout,
    stderr: ledger.stderr
  });
}

const allBlockers = uniqueBlockers([...(closure.blockers ?? []), ...(latest.blockers ?? [])]);
if (allBlockers.length > 0) {
  const blocker = allowBlocked ? warn : fail;
  blocker('release blockers are recorded in package metadata.', { blockers: allBlockers });
}

const report = {
  generatedAt: new Date().toISOString(),
  outDir: relative(outDir),
  allowBlocked,
  passed: failures.length === 0,
  failures,
  warnings
};
writeJson(path.join(outDir, 'release-verification.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(report.passed ? 0 : 1);

function readJsonOrNull(file) {
  try {
    if (!file || !fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function uniqueBlockers(blockers) {
  const seen = new Set();
  return blockers.filter((blocker) => {
    const key = `${blocker.kind ?? ''}\0${blocker.message ?? ''}\0${blocker.log ?? ''}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
