import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { validateFeedDocument } from './linux-update-feed.mjs';

function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function isInside(parent, child) {
  return child === parent || child.startsWith(`${parent}${path.sep}`);
}

function confinedFile(repoRoot, relPath) {
  const root = fs.realpathSync(repoRoot);
  if (typeof relPath !== 'string' || relPath.length === 0 || path.isAbsolute(relPath)) return null;
  const lexical = path.resolve(root, relPath);
  if (!isInside(root, lexical) || !fs.existsSync(lexical)) return null;
  const real = fs.realpathSync(lexical);
  return isInside(root, real) && fs.statSync(real).isFile() ? real : null;
}

function normalizeSidecar(value) {
  return typeof value === 'string' ? { file: value } : value;
}

/**
 * Verify a complete local release graph without executing external commands.
 * Sigstore cryptographic verification remains an outer verifier responsibility.
 */
export function verifyLinuxReleaseCandidate(input) {
  const {
    repoRoot,
    manifest,
    closure,
    provenance,
    latest,
    smokeSummary,
    publicKeyPem,
    expectedHead,
    expectedVersion,
    expectedCosignIdentity,
    phase = 'pre-attestation',
    requireParity = true
  } = input;
  const failures = [];
  const fail = (message, detail = {}) => failures.push({ message, ...detail });
  const allowBlockedLifecycle = !requireParity && closure?.allowBlockedLifecycle === true;
  if (requireParity && closure?.allowBlockedLifecycle === true) {
    fail('promotion closure cannot carry a blocked-lifecycle candidate exception.');
  }
  const allowedLifecycleBlock = (step) => {
    if (!allowBlockedLifecycle || !['update', 'rollback', 'dataPreservation'].includes(step)) return false;
    const row = smokeSummary?.lifecycle?.[step];
    return row?.status === 'blocked'
      && Array.isArray(row.blockers)
      && row.blockers.length === (manifest.supportedArchitectures?.length ?? 0)
      && row.blockers.every((blocker) => /(?:No previous same-architecture (?:Linux \.deb|Arch package) was supplied|Previous same-architecture Linux \.deb predates the daemon launcher contract)/u.test(blocker.reason ?? ''));
  };
  const read = (relPath, label) => {
    const full = confinedFile(repoRoot, relPath);
    if (!full) {
      fail(`${label} is missing or outside the repository`, { file: relPath ?? null });
      return null;
    }
    return fs.readFileSync(full);
  };

  if (closure?.schemaVersion !== 3) fail('package closure schemaVersion must be 3.');
  const expectedStage = requireParity ? 'promotion' : 'candidate';
  if (closure?.stage !== expectedStage) {
    fail(`package closure stage must be ${expectedStage}.`, { actual: closure?.stage ?? null });
  }
  const version = expectedVersion ?? closure?.version;
  const commit = expectedHead ?? closure?.git?.commit;
  for (const [label, value] of [
    ['closure version', closure?.version],
    ['provenance version', provenance?.version],
    ['update feed version', latest?.version]
  ]) {
    if (value !== version) fail(`${label} does not match expected version`, { expected: version, actual: value ?? null });
  }
  for (const [label, value] of [
    ['closure commit', closure?.git?.commit],
    ['provenance commit', provenance?.git?.commit],
    ['update feed commit', latest?.gitCommit]
  ]) {
    if (value !== commit) fail(`${label} does not match expected commit`, { expected: commit, actual: value ?? null });
  }
  if (closure?.tag !== `linux-v${version}`) {
    fail('package closure tag does not match linux release version.', { tag: closure?.tag ?? null });
  }

  let publicKey = null;
  try {
    publicKey = crypto.createPublicKey(publicKeyPem);
    if (publicKey.asymmetricKeyType !== 'ed25519') fail('release public key is not Ed25519.');
    const spki = publicKey.export({ type: 'spki', format: 'der' });
    const fingerprint = sha256Bytes(spki);
    if (fingerprint !== manifest.signing?.publicKeySpkiSha256) {
      fail('release public-key fingerprint does not match the pinned manifest value.', {
        expected: manifest.signing?.publicKeySpkiSha256 ?? null,
        actual: fingerprint
      });
    }
  } catch (error) {
    fail('release public key is invalid.', { error: String(error) });
  }

  const artifacts = Array.isArray(closure?.artifacts) ? closure.artifacts : [];
  const artifactByKey = new Map();
  const artifactByFile = new Map();
  for (const artifact of artifacts) {
    const key = `${artifact.type}:${artifact.architecture}`;
    if (artifactByKey.has(key)) fail(`duplicate artifact type/architecture: ${key}`);
    if (artifactByFile.has(artifact.file)) fail(`duplicate artifact path: ${artifact.file}`);
    artifactByKey.set(key, artifact);
    artifactByFile.set(artifact.file, artifact);
    const bytes = read(artifact.file, `${artifact.type ?? 'unknown'} artifact`);
    if (!bytes) continue;
    if (!/^[a-f0-9]{64}$/.test(artifact.sha256 ?? '')) fail(`invalid artifact sha256: ${artifact.file}`);
    if (sha256Bytes(bytes) !== artifact.sha256) fail(`artifact checksum drifted: ${artifact.file}`);
    if (bytes.length !== artifact.size) fail(`artifact size drifted: ${artifact.file}`);
    if (!manifest.supportedArchitectures?.includes(artifact.architecture)) {
      fail(`artifact has unsupported or missing architecture: ${artifact.file}`);
    }
  }
  const expectedArtifactKeys = new Set();
  for (const type of manifest.requiredArtifacts ?? []) {
    for (const architecture of manifest.supportedArchitectures ?? []) {
      const key = `${type}:${architecture}`;
      expectedArtifactKeys.add(key);
      if (!artifactByKey.has(key)) fail(`required ${key} artifact is absent from package closure.`);
    }
  }
  for (const key of artifactByKey.keys()) {
    if (!expectedArtifactKeys.has(key)) fail(`unexpected artifact type/architecture: ${key}`);
  }
  if (artifacts.length !== expectedArtifactKeys.size) {
    fail('package closure has missing or extra release artifacts.');
  }

  const feedFailures = validateFeedDocument(latest);
  for (const message of feedFailures) fail(`update feed schema: ${message}`);
  if (latest?.signature?.publicKeySpkiSha256 !== manifest.signing?.publicKeySpkiSha256) {
    fail('update feed signing fingerprint does not match the pinned manifest value.');
  }
  const feedArtifacts = Array.isArray(latest?.artifacts) ? latest.artifacts : [];
  const feedByKey = new Map();
  for (const artifact of feedArtifacts) {
    const key = `${artifact?.type}:${artifact?.architecture}`;
    if (feedByKey.has(key)) fail(`duplicate update feed artifact: ${key}`);
    feedByKey.set(key, artifact);
    const closureArtifact = artifactByKey.get(key);
    if (!closureArtifact) continue;
    if (artifact.sha256 !== closureArtifact.sha256 || artifact.size !== closureArtifact.size) {
      fail(`update feed artifact does not match package closure: ${key}`);
    }
    let artifactName = null;
    let signatureName = null;
    try {
      artifactName = path.basename(new URL(artifact.url).pathname);
      signatureName = path.basename(new URL(artifact.signatureUrl).pathname);
    } catch {
      // Schema validation already records malformed URLs.
    }
    if (artifactName && artifactName !== path.basename(closureArtifact.file)) {
      fail(`update feed artifact URL does not name the closure artifact: ${key}`);
    }
    const signature = Array.isArray(provenance?.signatures)
      ? provenance.signatures.find((row) => row.artifact === closureArtifact.file)
      : null;
    if (signatureName && signature && signatureName !== path.basename(signature.signature)) {
      fail(`update feed signature URL does not name the detached signature: ${key}`);
    }
  }
  if (feedByKey.size !== expectedArtifactKeys.size) {
    fail('update feed does not exactly cover the package closure.');
  }

  const signatureRows = Array.isArray(provenance?.signatures) ? provenance.signatures : [];
  const signaturesByArtifact = new Map();
  for (const signature of signatureRows) {
    if (!artifactByFile.has(signature.artifact)) fail(`signature targets an unknown artifact: ${signature.artifact}`);
    if (signaturesByArtifact.has(signature.artifact)) fail(`duplicate signature for artifact: ${signature.artifact}`);
    signaturesByArtifact.set(signature.artifact, signature);
    if (signature.algorithm !== 'Ed25519') fail(`signature algorithm must be Ed25519: ${signature.artifact}`);
    const artifactBytes = read(signature.artifact, 'signed artifact');
    const signatureBytes = read(signature.signature, 'detached Ed25519 signature');
    if (!artifactBytes || !signatureBytes || !publicKey) continue;
    if (signatureBytes.length !== 64) fail(`Ed25519 signature must be 64 bytes: ${signature.signature}`);
    if (!crypto.verify(null, artifactBytes, publicKey, signatureBytes)) {
      fail(`Ed25519 signature verification failed: ${signature.artifact}`);
    }
  }
  for (const artifact of artifacts) {
    if (!signaturesByArtifact.has(artifact.file)) fail(`artifact has no detached Ed25519 signature: ${artifact.file}`);
  }
  if (signatureRows.length !== artifacts.length) fail('signature set does not exactly cover the artifact closure.');

  const requiredSidecars = [
    'checksums',
    'sbom',
    'vex',
    'provenancePredicate',
    'sourceArchive',
    'architectureSessions',
    'packageSmoke',
    'updateFeed',
    'updateFeedSignature'
  ];
  if (requireParity) requiredSidecars.push('parityAttestation');
  const sidecarBytes = new Map();
  for (const kind of requiredSidecars) {
    const sidecar = normalizeSidecar(closure?.sidecars?.[kind]);
    if (!sidecar?.file) {
      fail(`${kind} sidecar is absent from package closure.`);
      continue;
    }
    const bytes = read(sidecar.file, `${kind} sidecar`);
    if (!bytes) continue;
    sidecarBytes.set(kind, bytes);
    if (!/^[a-f0-9]{64}$/.test(sidecar.sha256 ?? '')) {
      fail(`${kind} sidecar is not hash-bound by the closure.`);
    } else if (sha256Bytes(bytes) !== sidecar.sha256) {
      fail(`${kind} sidecar checksum drifted.`);
    }
    if (sidecar.size !== bytes.length) fail(`${kind} sidecar size drifted.`);
  }
  for (const kind of ['architectureSessions', 'packageSmoke']) {
    const closureRecord = normalizeSidecar(closure?.sidecars?.[kind]);
    const provenanceRecord = normalizeSidecar(provenance?.[kind]);
    if (
      !closureRecord
      || !provenanceRecord
      || closureRecord.file !== provenanceRecord.file
      || closureRecord.sha256 !== provenanceRecord.sha256
      || closureRecord.size !== provenanceRecord.size
    ) {
      fail(`${kind} is not identically bound by the package closure and attested provenance.`);
    }
  }

  const checksumBytes = sidecarBytes.get('checksums');
  if (checksumBytes) {
    const entries = new Map();
    for (const line of checksumBytes.toString('utf8').split('\n').filter(Boolean)) {
      const match = line.match(/^([a-f0-9]{64})  (.+)$/);
      if (!match) {
        fail('checksum sidecar contains an invalid line.', { line });
        continue;
      }
      if (entries.has(match[2])) fail(`duplicate checksum target: ${match[2]}`);
      entries.set(match[2], match[1]);
    }
    for (const artifact of artifacts) {
      if (entries.get(artifact.file) !== artifact.sha256) fail(`checksum sidecar does not match artifact: ${artifact.file}`);
    }
    for (const target of entries.keys()) {
      if (!artifactByFile.has(target)) fail(`checksum sidecar has extra target: ${target}`);
    }
    if (entries.size !== artifacts.length) fail('checksum sidecar does not exactly cover the artifact closure.');
  }

  const parityBytes = sidecarBytes.get('parityAttestation');
  if (parityBytes) {
    try {
      const parity = JSON.parse(parityBytes.toString('utf8'));
      if (parity.targetHead !== commit || parity.promotionPassed !== true || parity.productParityClaim !== true) {
        fail('parity attestation is not green for the release commit.');
      }
    } catch {
      fail('parity attestation is invalid JSON.');
    }
  }

  const updateFeedBytes = sidecarBytes.get('updateFeed');
  const updateFeedSignatureBytes = sidecarBytes.get('updateFeedSignature');
  if (updateFeedBytes) {
    try {
      const boundFeed = JSON.parse(updateFeedBytes.toString('utf8'));
      if (JSON.stringify(boundFeed) !== JSON.stringify(latest)) {
        fail('parsed update feed does not equal the hash-bound feed sidecar.');
      }
    } catch {
      fail('hash-bound update feed sidecar is invalid JSON.');
    }
  }
  if (updateFeedBytes && updateFeedSignatureBytes && publicKey) {
    if (updateFeedSignatureBytes.length !== 64) {
      fail('update feed Ed25519 signature must be 64 bytes.');
    } else if (!crypto.verify(null, updateFeedBytes, publicKey, updateFeedSignatureBytes)) {
      fail('update feed detached Ed25519 signature verification failed.');
    }
  }

  const packageSmokeBytes = sidecarBytes.get('packageSmoke');
  if (packageSmokeBytes) {
    try {
      const boundSmoke = JSON.parse(packageSmokeBytes.toString('utf8'));
      if (JSON.stringify(boundSmoke) !== JSON.stringify(smokeSummary)) {
        fail('parsed package smoke summary does not equal the hash-bound sidecar.');
      }
    } catch {
      fail('hash-bound package smoke summary is invalid JSON.');
    }
  }

  if ((closure?.blockers ?? []).length > 0) {
    fail('release metadata contains promotion blockers.');
  }
  const requiredLifecycle = ['guiLaunch', 'daemonLaunch', 'versionReadback', 'update', 'rollback', 'dataPreservation'];
  if (smokeSummary?.passed !== true || (smokeSummary?.failedCount ?? 1) !== 0) {
    if (!allowBlockedLifecycle || smokeSummary?.promotionBlocked !== true
        || ['guiLaunch', 'daemonLaunch', 'versionReadback'].some((step) => smokeSummary?.lifecycle?.[step]?.status !== 'passed')
        || ['update', 'rollback', 'dataPreservation'].some((step) => !allowedLifecycleBlock(step))) {
      fail('package smoke summary is not green.');
    }
  }
  for (const step of requiredLifecycle) {
    if (smokeSummary?.lifecycle?.[step]?.status !== 'passed' && !allowedLifecycleBlock(step)) {
      fail(`package lifecycle proof is not passed: ${step}`);
    }
  }

  const expectedIdentity = expectedCosignIdentity
    ?? manifest.signing?.cosignIdentityTemplate?.replace('{version}', version);
  if (provenance?.expectedCosignIdentity !== expectedIdentity) fail('provenance has the wrong expected cosign identity.');
  if (provenance?.expectedCosignIssuer !== manifest.signing?.cosignIssuer) fail('provenance has the wrong expected cosign issuer.');
  if (phase === 'final') {
    for (const artifact of artifacts) {
      const bundle = `${artifact.file}.sigstore.json`;
      if (!confinedFile(repoRoot, bundle)) fail(`final Sigstore bundle is missing: ${bundle}`);
    }
  } else if (phase !== 'pre-attestation') {
    fail(`unknown verification phase: ${phase}`);
  }

  return { passed: failures.length === 0, failures };
}
