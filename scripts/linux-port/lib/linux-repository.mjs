import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const SUPPORTED_CHANNELS = new Set(['stable', 'prerelease', 'nightly']);
const SUPPORTED_ARCHITECTURES = ['aarch64', 'x86_64'];
const APT_ARCHITECTURES = { aarch64: 'arm64', x86_64: 'amd64' };
const RPM_ARCHITECTURES = { aarch64: 'aarch64', x86_64: 'x86_64' };
const APT_VALID_FOR_HOURS = 168;
const SIGNING_KEY_MINIMUM_REMAINING_DAYS = 30;

export function canonicalJSON(value) {
  const canonicalize = (item) => {
    if (Array.isArray(item)) return item.map(canonicalize);
    if (item && typeof item === 'object') {
      return Object.fromEntries(Object.keys(item).sort().map((key) => [key, canonicalize(item[key])]));
    }
    return item;
  };
  return `${JSON.stringify(canonicalize(value), null, 2)}\n`;
}

export function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

export function sha256File(file) {
  return sha256Bytes(fs.readFileSync(file));
}

export function packageSetRoot(rows) {
  const normalized = rows
    .map((row) => ({
      architecture: row.architecture,
      file: row.file,
      sha256: row.sha256,
      size: row.size,
      type: row.type
    }))
    .sort((left, right) => `${left.type}:${left.architecture}`.localeCompare(`${right.type}:${right.architecture}`));
  return sha256Bytes(Buffer.from(canonicalJSON(normalized), 'utf8'));
}

export function hasTrustedRpmSignatureOutput(output, signingFingerprint) {
  const text = output ?? '';
  const keyId = text.match(/key\s+id\s+([a-f0-9]{8,16})/iu)?.[1]?.toUpperCase();
  return /(?:^|\s)signatures?\s+ok(?=\s|,|$)/iu.test(text)
    && !/(?:not\s+ok|unsigned|nokey)/iu.test(text)
    && typeof signingFingerprint === 'string'
    && Boolean(keyId)
    && signingFingerprint.toUpperCase().endsWith(keyId);
}

export function parseAptReleaseSha256(value) {
  const records = new Map();
  const lines = String(value ?? '').split(/\r?\n/u);
  const start = lines.findIndex((line) => line === 'SHA256:');
  if (start < 0) return records;
  for (const line of lines.slice(start + 1)) {
    if (/^[A-Za-z][A-Za-z0-9-]*:/u.test(line)) break;
    const match = line.match(/^ ([a-f0-9]{64})\s+([0-9]+)\s+(.+)$/u);
    if (!match) continue;
    records.set(match[3], { sha256: match[1], size: Number(match[2]) });
  }
  return records;
}

export function selectOpenPgpSigningKey(listing, minimumValidUntilEpoch, expectedSigningFingerprint = null) {
  const lines = String(listing ?? '').split('\n').filter(Boolean);
  const keys = [];
  for (let index = 0; index < lines.length; index += 1) {
    const fields = lines[index].split(':');
    if (!['sec', 'pub', 'ssb', 'sub'].includes(fields[0])) continue;
    const fingerprintLine = lines.slice(index + 1).find((line) => {
      const kind = line.split(':')[0];
      return kind === 'fpr' || ['sec', 'pub', 'ssb', 'sub'].includes(kind);
    });
    if (!fingerprintLine?.startsWith('fpr:')) throw new Error('repository OpenPGP key has no full fingerprint');
    keys.push({
      primary: fields[0] === 'sec' || fields[0] === 'pub',
      validity: fields[1],
      bits: Number(fields[2] || 0),
      algorithmId: Number(fields[3] || 0),
      createdAt: Number(fields[5] || 0),
      expiresAt: Number(fields[6] || 0),
      capabilities: fields[11] ?? '',
      fingerprint: fingerprintLine.split(':')[9]?.toUpperCase()
    });
  }
  const primaryKeys = keys.filter((key) => key.primary);
  if (primaryKeys.length !== 1) {
    throw new Error(`repository keyring must contain exactly one primary key, found ${primaryKeys.length}`);
  }
  const primary = primaryKeys[0];
  validateOpenPgpKey(primary, minimumValidUntilEpoch, 'primary');
  const candidates = keys.filter((key) => /s/u.test(key.capabilities) && !['r', 'e', 'd'].includes(key.validity));
  const signingKey = expectedSigningFingerprint
    ? candidates.find((key) => key.fingerprint === expectedSigningFingerprint)
    : (candidates.find((key) => !key.primary) ?? candidates.find((key) => key.primary));
  if (!signingKey) throw new Error('repository keyring has no usable signing key or subkey');
  validateOpenPgpKey(signingKey, minimumValidUntilEpoch, 'signing');
  return {
    primaryFingerprint: primary.fingerprint,
    signingFingerprint: signingKey.fingerprint,
    signingAlgorithm: openPgpAlgorithm(signingKey),
    signingKeyExpiresAt: signingKey.expiresAt
  };
}

export function validateDistributionChannels(config) {
  const failures = [];
  if (config?.schemaVersion !== 1) failures.push('distribution channel schemaVersion must be 1');
  if (config?.repositoryMetadata?.aptValidForHours !== APT_VALID_FOR_HOURS) {
    failures.push(`repository metadata aptValidForHours must be ${APT_VALID_FOR_HOURS}`);
  }
  if (config?.repositoryMetadata?.signingKeyMinimumRemainingDays !== SIGNING_KEY_MINIMUM_REMAINING_DAYS) {
    failures.push(`repository metadata signingKeyMinimumRemainingDays must be ${SIGNING_KEY_MINIMUM_REMAINING_DAYS}`);
  }
  for (const kind of ['apt', 'rpm']) {
    if (config?.[kind]?.status !== 'source-ready') failures.push(`${kind} channel status must be source-ready`);
    try {
      const base = new URL(config?.[kind]?.baseUrl);
      if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash) {
        failures.push(`${kind} baseUrl must be a credential-free HTTPS URL`);
      }
    } catch {
      failures.push(`${kind} baseUrl must be a valid URL`);
    }
    if (JSON.stringify(config?.[kind]?.architectures) !== JSON.stringify(kind === 'apt' ? APT_ARCHITECTURES : RPM_ARCHITECTURES)) {
      failures.push(`${kind} architecture mapping is not canonical`);
    }
  }
  const signing = config?.signing;
  if (!['configured', 'unconfigured'].includes(signing?.status)) failures.push('signing status must be configured or unconfigured');
  if (signing?.status === 'configured') {
    if (typeof signing.publicKey !== 'string' || !signing.publicKey) failures.push('configured signing requires publicKey');
    if (!/^[A-F0-9]{40,64}$/.test(signing.fingerprint ?? '')) failures.push('configured signing requires a full uppercase OpenPGP fingerprint');
    if (!/^[A-F0-9]{40,64}$/.test(signing.signingFingerprint ?? '')) failures.push('configured signing requires a pinned signing-subkey fingerprint');
  } else if (signing?.publicKey !== null || signing?.fingerprint !== null || signing?.signingFingerprint !== null
      || signing?.provisioning !== 'required') {
    failures.push('unconfigured signing must declare null key/fingerprints and required provisioning');
  }
  return failures;
}

export function loadReleasePackageSet({ repoRoot, releaseOut, version, channel }) {
  requireVersionAndChannel(version, channel);
  const closurePath = path.join(releaseOut, 'package-closure.json');
  const closure = readJson(closurePath, 'package closure');
  if (closure.schemaVersion !== 3) throw new Error('package closure schemaVersion must be 3');
  if (closure.version !== version || closure.tag !== `linux-v${version}`) throw new Error('package closure version/tag mismatch');
  if (!/^[a-f0-9]{40}$/.test(closure.git?.commit ?? '')) throw new Error('package closure commit is invalid');
  const generatedAtEpoch = Date.parse(closure.generatedAt ?? '') / 1000;
  if (!Number.isFinite(generatedAtEpoch) || generatedAtEpoch <= 0) throw new Error('package closure generatedAt is invalid');
  if (generatedAtEpoch > Date.now() / 1000 + 300) throw new Error('package closure generatedAt exceeds the five-minute future-skew limit');
  const packages = (closure.artifacts ?? [])
    .filter((row) => row.type === 'deb' || row.type === 'rpm')
    .map((row) => {
      if (!SUPPORTED_ARCHITECTURES.includes(row.architecture)) throw new Error(`unsupported package architecture: ${row.architecture}`);
      const full = confinedRegularFile(repoRoot, row.file);
      if (!full) throw new Error(`package artifact is missing or outside release output: ${row.file}`);
      const realReleaseOut = fs.realpathSync(releaseOut);
      if (full !== realReleaseOut && !full.startsWith(`${realReleaseOut}${path.sep}`)) {
        throw new Error(`package artifact is outside release output: ${row.file}`);
      }
      if (sha256File(full) !== row.sha256 || fs.statSync(full).size !== row.size) throw new Error(`package artifact drifted: ${row.file}`);
      return { ...row, full };
    });
  const expected = new Set(['deb:aarch64', 'deb:x86_64', 'rpm:aarch64', 'rpm:x86_64']);
  const seen = new Set();
  for (const row of packages) {
    const key = `${row.type}:${row.architecture}`;
    if (!expected.has(key) || seen.has(key)) throw new Error(`duplicate or unexpected release package: ${key}`);
    seen.add(key);
  }
  if (seen.size !== expected.size) throw new Error('package closure does not contain the complete deb/rpm architecture matrix');
  return { closure, closurePath, packages, packageSetRootSha256: packageSetRoot(packages), generatedAtEpoch };
}

export function buildLinuxRepositories({ repoRoot, releaseOut, configPath, version, channel, privateKeyBytes }) {
  requireVersionAndChannel(version, channel);
  const config = readJson(configPath, 'distribution channel config');
  const configFailures = validateDistributionChannels(config);
  if (configFailures.length) throw new Error(configFailures.join('; '));
  if (config.signing.status !== 'configured') {
    throw new Error('repository OpenPGP signing is unconfigured; provision a recoverable public key, fingerprint, and matching CI private key');
  }
  const publicKeyPath = confinedRegularFile(repoRoot, config.signing.publicKey);
  if (!publicKeyPath) throw new Error('configured repository public key is missing or outside the repository');
  const source = loadReleasePackageSet({ repoRoot, releaseOut, version, channel });
  fs.mkdirSync(releaseOut, { recursive: true });
  const finalRepositoryRoot = path.join(releaseOut, 'repositories');
  const repositoryRoot = fs.mkdtempSync(path.join(releaseOut, '.repositories-staging-'));
  const signingHome = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-repository-signing-'));
  fs.chmodSync(signingHome, 0o700);
  try {
    const keyFile = path.join(signingHome, 'private-key.asc');
    fs.writeFileSync(keyFile, privateKeyBytes, { mode: 0o600 });
    runChecked('gpg', ['--homedir', signingHome, '--batch', '--import', keyFile], { secretPaths: [keyFile] });
    fs.rmSync(keyFile, { force: true });
    const validUntilEpoch = source.generatedAtEpoch + (config.repositoryMetadata.aptValidForHours * 60 * 60);
    const minimumKeyValidityEpoch = validUntilEpoch
      + (config.repositoryMetadata.signingKeyMinimumRemainingDays * 24 * 60 * 60);
    const signingKey = secretSigningKey(signingHome, minimumKeyValidityEpoch, config.signing.signingFingerprint);
    const fingerprint = signingKey.primaryFingerprint;
    if (fingerprint !== config.signing.fingerprint) throw new Error('repository private key fingerprint does not match committed configuration');
    if (signingKey.signingFingerprint !== config.signing.signingFingerprint) {
      throw new Error('repository signing key does not match the committed signing-subkey fingerprint');
    }
    const publicSigningKey = publicKeyMetadata(publicKeyPath, minimumKeyValidityEpoch, config.signing.signingFingerprint);
    if (publicSigningKey.primaryFingerprint !== fingerprint
        || publicSigningKey.signingFingerprint !== signingKey.signingFingerprint) {
      throw new Error('committed repository public key identity does not match the private signing key');
    }

    const signingFingerprint = signingKey.signingFingerprint;
    const apt = buildAptRepository({ repoRoot, repositoryRoot, config, source, version, channel, signingHome, fingerprint, signingFingerprint });
    const rpm = buildRpmRepository({ repoRoot, repositoryRoot, config, source, version, channel, signingHome, fingerprint, signingFingerprint });
    const files = collectFiles(repositoryRoot, new Set(['repository-closure.json', 'repository-closure.json.asc']));
    const closure = {
      schemaVersion: 1,
      product: 'OpenBurnBar',
      version,
      channel,
      gitCommit: source.closure.git.commit,
      architectures: SUPPORTED_ARCHITECTURES,
      packageSetRootSha256: source.packageSetRootSha256,
      signing: {
        algorithm: 'OpenPGP',
        fingerprint,
        signingFingerprint,
        signingAlgorithm: signingKey.signingAlgorithm,
        signingKeyExpiresAt: new Date(signingKey.signingKeyExpiresAt * 1000).toISOString(),
        publicKeySha256: sha256File(publicKeyPath)
      },
      packages: [...apt.packages, ...rpm.packages],
      repositories: { apt: apt.summary, rpm: rpm.summary },
      files,
      lifecycleRequired: {
        architectures: SUPPORTED_ARCHITECTURES,
        operations: ['install', 'remove'],
        packageManagers: ['apt', 'dnf']
      }
    };
    const closurePath = path.join(repositoryRoot, 'repository-closure.json');
    fs.writeFileSync(closurePath, canonicalJSON(closure));
    signDetached({ signingHome, fingerprint: signingFingerprint, input: closurePath, output: `${closurePath}.asc` });
    fs.rmSync(finalRepositoryRoot, { recursive: true, force: true });
    fs.renameSync(repositoryRoot, finalRepositoryRoot);
    return {
      repositoryRoot: finalRepositoryRoot,
      closure,
      closurePath: path.join(finalRepositoryRoot, 'repository-closure.json')
    };
  } finally {
    spawnSync('gpgconf', ['--homedir', signingHome, '--kill', 'all'], {
      env: { PATH: process.env.PATH, HOME: process.env.HOME },
      stdio: 'ignore'
    });
    fs.rmSync(signingHome, { recursive: true, force: true });
    fs.rmSync(repositoryRoot, { recursive: true, force: true });
  }
}

export function verifyLinuxRepositories({ repoRoot, releaseOut, configPath, version, channel }) {
  const failures = [];
  const fail = (message) => failures.push(message);
  let config;
  let source;
  try {
    requireVersionAndChannel(version, channel);
    config = readJson(configPath, 'distribution channel config');
    for (const failure of validateDistributionChannels(config)) fail(failure);
    if (config.signing?.status !== 'configured') fail('repository OpenPGP signing is not configured');
    source = loadReleasePackageSet({ repoRoot, releaseOut, version, channel });
  } catch (error) {
    fail(error.message);
  }
  const repositoryRoot = path.join(releaseOut, 'repositories');
  const closurePath = path.join(repositoryRoot, 'repository-closure.json');
  let closure = {};
  try { closure = readJson(closurePath, 'repository closure'); } catch (error) { fail(error.message); }
  const publicKeyPath = config?.signing?.publicKey ? confinedRegularFile(repoRoot, config.signing.publicKey) : null;
  if (!publicKeyPath) fail('repository public key is missing or outside the repository');
  if (publicKeyPath) {
    try {
      const publicSigningKey = publicKeyMetadata(publicKeyPath, 0, config?.signing?.signingFingerprint);
      if (publicSigningKey.primaryFingerprint !== config?.signing?.fingerprint
          || publicSigningKey.signingFingerprint !== config?.signing?.signingFingerprint) {
        fail('repository public-key fingerprint does not match committed configuration');
      }
    } catch (error) {
      fail(error.message);
    }
  }
  if (closure.schemaVersion !== 1) fail('repository closure schemaVersion must be 1');
  if (closure.product !== 'OpenBurnBar') fail('repository closure product mismatch');
  if (closure.version !== version || closure.channel !== channel) fail('repository closure version/channel mismatch');
  if (source && (closure.gitCommit !== source.closure.git.commit || closure.packageSetRootSha256 !== source.packageSetRootSha256)) {
    fail('repository closure does not bind the current release package set');
  }
  if (JSON.stringify(closure.architectures) !== JSON.stringify(SUPPORTED_ARCHITECTURES)) fail('repository closure architecture matrix mismatch');
  if (JSON.stringify(closure.lifecycleRequired) !== JSON.stringify({
    architectures: SUPPORTED_ARCHITECTURES,
    operations: ['install', 'remove'],
    packageManagers: ['apt', 'dnf']
  })) fail('repository closure lifecycle requirement is not canonical');
  if (closure.signing?.fingerprint !== config?.signing?.fingerprint
      || closure.signing?.signingFingerprint !== config?.signing?.signingFingerprint) {
    fail('repository closure fingerprint mismatch');
  }
  if (!/^[A-F0-9]{40,64}$/u.test(closure.signing?.signingFingerprint ?? '')) fail('repository closure signing-key fingerprint is invalid');
  if (!['EdDSA', 'ECDSA', 'RSA-3072+'].includes(closure.signing?.signingAlgorithm)) fail('repository closure signing algorithm is invalid');
  const signingKeyExpiresAt = Date.parse(closure.signing?.signingKeyExpiresAt ?? '') / 1000;
  const aptValidUntil = Date.parse(closure.repositories?.apt?.validUntil ?? '') / 1000;
  const minimumKeyValidityEpoch = aptValidUntil
    + ((config?.repositoryMetadata?.signingKeyMinimumRemainingDays ?? 0) * 24 * 60 * 60);
  if (!Number.isFinite(signingKeyExpiresAt) || signingKeyExpiresAt < minimumKeyValidityEpoch) {
    fail('repository signing key does not remain valid beyond the metadata horizon');
  }
  if (publicKeyPath) {
    try {
      const publicSigningKey = publicKeyMetadata(publicKeyPath, minimumKeyValidityEpoch, config?.signing?.signingFingerprint);
      if (publicSigningKey.signingFingerprint !== closure.signing?.signingFingerprint
          || publicSigningKey.signingAlgorithm !== closure.signing?.signingAlgorithm
          || publicSigningKey.signingKeyExpiresAt !== signingKeyExpiresAt) {
        fail('repository closure signing-key metadata does not match the committed public key');
      }
    } catch (error) {
      fail(error.message);
    }
  }
  if (publicKeyPath && closure.signing?.publicKeySha256 !== sha256File(publicKeyPath)) fail('repository closure public-key hash mismatch');

  if (publicKeyPath && fs.existsSync(closurePath)) {
    try { verifyDetached(publicKeyPath, `${closurePath}.asc`, closurePath, closure.signing?.signingFingerprint); } catch (error) { fail(error.message); }
  } else {
    fail('repository closure or detached signature is missing');
  }
  const expectedFiles = new Set();
  for (const record of closure.files ?? []) {
    if (expectedFiles.has(record.file)) fail(`duplicate repository closure file: ${record.file}`);
    expectedFiles.add(record.file);
    const full = confinedRegularFile(repositoryRoot, record.file);
    if (!full) { fail(`repository file is missing or outside output: ${record.file}`); continue; }
    if (sha256File(full) !== record.sha256 || fs.statSync(full).size !== record.size) fail(`repository file drifted: ${record.file}`);
  }
  for (const record of collectFiles(repositoryRoot, new Set([
    'repository-closure.json',
    'repository-closure.json.asc',
    'repository-lifecycle.json'
  ]), (relative) => relative.endsWith('.sigstore.json') || relative.endsWith('.predicate.json'))) {
    if (!expectedFiles.has(record.file)) fail(`unbound repository file: ${record.file}`);
  }

  if (publicKeyPath) {
    verifyAptRepository({ repositoryRoot, closure, publicKeyPath, source, version, channel, fail });
    verifyRpmRepository({ repositoryRoot, closure, publicKeyPath, source, version, channel, fail });
  }
  return { passed: failures.length === 0, failures, closure };
}

function buildAptRepository({ repoRoot, repositoryRoot, config, source, version, channel, signingHome, fingerprint, signingFingerprint }) {
  const root = path.join(repositoryRoot, 'apt');
  const pool = path.join(root, 'pool/main/o/openburnbar');
  fs.mkdirSync(pool, { recursive: true });
  const keyring = path.join(root, 'openburnbar-archive-keyring.gpg');
  runChecked('gpg', ['--homedir', signingHome, '--batch', '--yes', '--output', keyring, '--export', fingerprint]);
  renderTemplate(repoRoot, config.apt.sourcesTemplate, path.join(root, `openburnbar-${channel}.sources`), {
    APT_BASE_URL: config.apt.baseUrl,
    CHANNEL: channel,
    APT_COMPONENT: config.apt.component,
    APT_INSTALLED_KEYRING: config.apt.installedKeyring
  });
  const packages = [];
  for (const row of source.packages.filter((item) => item.type === 'deb')) {
    const destination = path.join(pool, path.basename(row.full));
    fs.copyFileSync(row.full, destination);
    packages.push(packageRecord(repositoryRoot, row, destination));
  }
  const dist = path.join(root, 'dists', channel);
  for (const architecture of SUPPORTED_ARCHITECTURES) {
    const aptArchitecture = config.apt.architectures[architecture];
    const binary = path.join(dist, config.apt.component, `binary-${aptArchitecture}`);
    fs.mkdirSync(binary, { recursive: true });
    const result = runChecked('dpkg-scanpackages', ['--arch', aptArchitecture, 'pool/main/o/openburnbar', '/dev/null'], { cwd: root });
    const packagesFile = path.join(binary, 'Packages');
    fs.writeFileSync(packagesFile, result.stdout);
    const compressed = spawnSync('gzip', ['-n', '-9', '-c', packagesFile], { cwd: root, encoding: null });
    if (compressed.status !== 0) throw new Error(`gzip Packages failed: ${String(compressed.stderr)}`);
    fs.writeFileSync(`${packagesFile}.gz`, compressed.stdout);
    for (const indexFile of [packagesFile, `${packagesFile}.gz`]) {
      const byHash = path.join(binary, 'by-hash/SHA256', sha256File(indexFile));
      fs.mkdirSync(path.dirname(byHash), { recursive: true });
      fs.copyFileSync(indexFile, byHash);
    }
  }
  const release = path.join(dist, 'Release');
  const epoch = Math.floor(source.generatedAtEpoch);
  const releaseDate = new Date(epoch * 1000).toUTCString();
  const validUntil = new Date((epoch + (config.repositoryMetadata.aptValidForHours * 60 * 60)) * 1000).toUTCString();
  const releaseArgs = [
    '-o', `APT::FTPArchive::Release::Origin=${config.apt.origin}`,
    '-o', `APT::FTPArchive::Release::Label=${config.apt.label}`,
    '-o', `APT::FTPArchive::Release::Suite=${channel}`,
    '-o', `APT::FTPArchive::Release::Codename=${channel}`,
    '-o', `APT::FTPArchive::Release::Architectures=${Object.values(config.apt.architectures).join(' ')}`,
    '-o', `APT::FTPArchive::Release::Components=${config.apt.component}`,
    '-o', 'APT::FTPArchive::Release::Acquire-By-Hash=yes',
    '-o', `APT::FTPArchive::Release::Date=${releaseDate}`,
    '-o', `APT::FTPArchive::Release::Valid-Until=${validUntil}`,
    'release', `dists/${channel}`
  ];
  const releaseResult = runChecked('apt-ftparchive', releaseArgs, { cwd: root, env: { SOURCE_DATE_EPOCH: String(epoch) } });
  fs.writeFileSync(release, releaseResult.stdout);
  signDetached({ signingHome, fingerprint: signingFingerprint, input: release, output: path.join(dist, 'Release.gpg') });
  runChecked('gpg', [
    '--homedir', signingHome, '--batch', '--yes', '--pinentry-mode', 'loopback', '--local-user', `${signingFingerprint}!`,
    '--digest-algo', 'SHA256', '--clearsign', '--output', path.join(dist, 'InRelease'), release
  ]);
  return {
    packages,
    summary: {
      baseUrl: config.apt.baseUrl,
      component: config.apt.component,
      architectures: config.apt.architectures,
      release: relativeUnix(repositoryRoot, release),
      inRelease: relativeUnix(repositoryRoot, path.join(dist, 'InRelease')),
      releaseSignature: relativeUnix(repositoryRoot, path.join(dist, 'Release.gpg')),
      releaseDate: new Date(epoch * 1000).toISOString(),
      validUntil: new Date((epoch + (config.repositoryMetadata.aptValidForHours * 60 * 60)) * 1000).toISOString()
    }
  };
}

function buildRpmRepository({ repoRoot, repositoryRoot, config, source, version, channel, signingHome, fingerprint, signingFingerprint }) {
  const root = path.join(repositoryRoot, 'rpm');
  fs.mkdirSync(root, { recursive: true });
  const armoredKey = path.join(root, 'RPM-GPG-KEY-openburnbar');
  runChecked('gpg', ['--homedir', signingHome, '--batch', '--yes', '--armor', '--output', armoredKey, '--export', fingerprint]);
  renderTemplate(repoRoot, config.rpm.repoTemplate, path.join(root, `openburnbar-${channel}.repo`), {
    RPM_REPOSITORY_ID: config.rpm.repositoryId,
    RPM_REPOSITORY_NAME: config.rpm.repositoryName,
    RPM_BASE_URL: config.rpm.baseUrl,
    CHANNEL: channel,
    RPM_INSTALLED_KEY: config.rpm.installedKey
  });
  const packages = [];
  const epoch = gitCommitEpoch(source.closure.git.commit);
  for (const architecture of SUPPORTED_ARCHITECTURES) {
    const rpmArchitecture = config.rpm.architectures[architecture];
    const directory = path.join(root, channel, rpmArchitecture);
    fs.mkdirSync(directory, { recursive: true });
    const sourceRow = source.packages.find((item) => item.type === 'rpm' && item.architecture === architecture);
    const destination = path.join(directory, path.basename(sourceRow.full));
    fs.copyFileSync(sourceRow.full, destination);
    const sourceIdentity = rpmIdentity(sourceRow.full);
    if (sourceIdentity.name !== 'open-burn-bar' || sourceIdentity.version !== version || sourceIdentity.architecture !== rpmArchitecture) {
      throw new Error(`release RPM identity is invalid: ${sourceRow.file}`);
    }
    runChecked('rpmsign', [
      '--define', `_gpg_name ${signingFingerprint}!`,
      '--define', `_gpg_path ${signingHome}`,
      '--define', '_gpg_digest_algo sha256',
      '--define', `__gpg ${commandPath('gpg')}`,
      '--addsign', destination
    ], { env: { GNUPGHOME: signingHome } });
    const signedIdentity = rpmIdentity(destination);
    if (!sourceIdentity.payloadDigest || JSON.stringify(signedIdentity) !== JSON.stringify(sourceIdentity)) {
      throw new Error(`RPM signing changed the package identity or payload: ${sourceRow.file}`);
    }
    packages.push({
      ...packageRecord(repositoryRoot, sourceRow, destination),
      sourceHeaderDigest: sourceIdentity.headerDigest,
      repositoryHeaderDigest: signedIdentity.headerDigest,
      sourcePayloadDigest: sourceIdentity.payloadDigest,
      repositoryPayloadDigest: signedIdentity.payloadDigest
    });
    runChecked('createrepo_c', [
      '--no-database', '--revision', String(epoch), '--set-timestamp-to-revision', directory
    ], { env: { SOURCE_DATE_EPOCH: String(epoch) } });
    const repomd = path.join(directory, 'repodata/repomd.xml');
    signDetached({ signingHome, fingerprint: signingFingerprint, input: repomd, output: `${repomd}.asc` });
  }
  return {
    packages,
    summary: {
      baseUrl: config.rpm.baseUrl,
      repositoryId: config.rpm.repositoryId,
      architectures: config.rpm.architectures,
      repomd: SUPPORTED_ARCHITECTURES.map((architecture) => relativeUnix(
        repositoryRoot,
        path.join(root, channel, config.rpm.architectures[architecture], 'repodata/repomd.xml')
      ))
    }
  };
}

function verifyAptRepository({ repositoryRoot, closure, publicKeyPath, source, version, channel, fail }) {
  const apt = closure.repositories?.apt;
  const release = apt?.release ? path.join(repositoryRoot, apt.release) : null;
  const inRelease = apt?.inRelease ? path.join(repositoryRoot, apt.inRelease) : null;
  const signature = apt?.releaseSignature ? path.join(repositoryRoot, apt.releaseSignature) : null;
  for (const [label, file] of [['apt Release', release], ['apt InRelease', inRelease], ['apt Release.gpg', signature]]) {
    if (!file || !confinedRegularFile(repositoryRoot, path.relative(repositoryRoot, file))) fail(`${label} is missing`);
  }
  try { verifyDetached(publicKeyPath, signature, release, closure.signing?.signingFingerprint); } catch (error) { fail(error.message); }
  try { verifyClearSigned(publicKeyPath, inRelease, closure.signing?.signingFingerprint); } catch (error) { fail(error.message); }
  const releaseBytes = release && fs.existsSync(release) ? fs.readFileSync(release, 'utf8') : '';
  if (!/^Acquire-By-Hash:\s*yes$/mu.test(releaseBytes)) fail('apt Release does not enable Acquire-By-Hash');
  const releaseHeaders = parseControlParagraph(releaseBytes.split(/^SHA256:$/mu)[0]);
  const releaseDateEpoch = Date.parse(releaseHeaders.Date ?? '') / 1000;
  const validUntilEpoch = Date.parse(releaseHeaders['Valid-Until'] ?? '') / 1000;
  const expectedReleaseDateEpoch = Date.parse(apt?.releaseDate ?? '') / 1000;
  const expectedValidUntilEpoch = Date.parse(apt?.validUntil ?? '') / 1000;
  if (!Number.isFinite(releaseDateEpoch) || releaseDateEpoch !== expectedReleaseDateEpoch) {
    fail('apt Release Date does not match the signed repository closure');
  }
  if (!Number.isFinite(validUntilEpoch) || validUntilEpoch !== expectedValidUntilEpoch
      || validUntilEpoch - releaseDateEpoch !== APT_VALID_FOR_HOURS * 60 * 60) {
    fail(`apt Release Valid-Until must be exactly ${APT_VALID_FOR_HOURS} hours after Date`);
  }
  if (source && releaseDateEpoch !== Math.floor(source.generatedAtEpoch)) {
    fail('apt Release Date does not match package-closure generation time');
  }
  if (validUntilEpoch <= Date.now() / 1000) fail('apt Release metadata is expired');
  const releaseSha256 = parseAptReleaseSha256(releaseBytes);
  for (const architecture of SUPPORTED_ARCHITECTURES) {
    const aptArch = APT_ARCHITECTURES[architecture];
    const packagesPath = path.join(repositoryRoot, 'apt/dists', channel, 'main', `binary-${aptArch}`, 'Packages');
    if (!fs.existsSync(packagesPath)) { fail(`apt Packages is missing for ${aptArch}`); continue; }
    const paragraphs = fs.readFileSync(packagesPath, 'utf8').trim().split(/\n\n+/u).filter(Boolean).map(parseControlParagraph);
    const expected = (closure.packages ?? []).filter((row) => row.type === 'deb' && row.architecture === architecture);
    if (paragraphs.length !== expected.length) fail(`apt Packages coverage mismatch for ${aptArch}`);
    for (const record of expected) {
      const match = paragraphs.find((row) => row.Filename === relativeUnix(path.join(repositoryRoot, 'apt'), path.join(repositoryRoot, record.repository.file)));
      if (!match || match.Package !== 'open-burn-bar' || match.Version !== version || match.Architecture !== aptArch
        || match.SHA256 !== record.repository.sha256 || Number(match.Size) !== record.repository.size) {
        fail(`apt Packages entry does not bind ${record.repository.file}`);
      }
    }
    for (const indexPath of [packagesPath, `${packagesPath}.gz`]) {
      if (!fs.existsSync(indexPath)) {
        fail(`apt index is missing: ${indexPath}`);
        continue;
      }
      const releasePath = relativeUnix(path.join(repositoryRoot, 'apt/dists', channel), indexPath);
      const releaseRecord = releaseSha256.get(releasePath);
      if (!releaseRecord || releaseRecord.sha256 !== sha256File(indexPath) || releaseRecord.size !== fs.statSync(indexPath).size) {
        fail(`apt Release does not bind ${releasePath}`);
      }
      const byHash = path.join(path.dirname(indexPath), 'by-hash/SHA256', sha256File(indexPath));
      if (!fs.existsSync(byHash) || sha256File(byHash) !== sha256File(indexPath)) {
        fail(`apt by-hash index is missing or invalid: ${releasePath}`);
      }
    }
  }
}

function verifyRpmRepository({ repositoryRoot, closure, publicKeyPath, source, channel, fail }) {
  const rpmDb = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-rpm-verify-'));
  try {
    try { runChecked('rpmkeys', ['--dbpath', rpmDb, '--import', publicKeyPath]); } catch (error) { fail(error.message); return; }
    for (const record of (closure.packages ?? []).filter((row) => row.type === 'rpm')) {
      const packagePath = confinedRegularFile(repositoryRoot, record.repository?.file);
      if (!packagePath) { fail(`RPM repository package is missing: ${record.repository?.file}`); continue; }
      try {
        const signatureCheck = runChecked('rpmkeys', ['--dbpath', rpmDb, '--checksig', '--verbose', packagePath]);
        if (!hasTrustedRpmSignatureOutput(
          `${signatureCheck.stdout}\n${signatureCheck.stderr}`,
          closure.signing?.signingFingerprint
        )) {
          fail(`RPM package has no trusted OpenPGP signature: ${record.repository?.file}`);
        }
      } catch (error) { fail(error.message); }
      const sourceRow = source?.packages.find((row) => row.type === 'rpm' && row.architecture === record.architecture);
      if (!sourceRow || record.source.sha256 !== sourceRow.sha256 || record.source.size !== sourceRow.size) {
        fail(`RPM source mapping drifted for ${record.architecture}`);
        continue;
      }
      try {
        const sourceIdentity = rpmIdentity(sourceRow.full);
        const repositoryIdentity = rpmIdentity(packagePath);
        if (JSON.stringify(repositoryIdentity) !== JSON.stringify(sourceIdentity)
            || repositoryIdentity.name !== 'open-burn-bar'
            || repositoryIdentity.architecture !== RPM_ARCHITECTURES[record.architecture]) {
          fail(`RPM identity or payload differs from release closure for ${record.architecture}`);
        }
      } catch (error) { fail(error.message); }
    }
    for (const architecture of SUPPORTED_ARCHITECTURES) {
      const architectureRoot = path.join(repositoryRoot, 'rpm', channel, RPM_ARCHITECTURES[architecture]);
      const repomd = path.join(architectureRoot, 'repodata/repomd.xml');
      try { verifyDetached(publicKeyPath, `${repomd}.asc`, repomd, closure.signing?.signingFingerprint); } catch (error) { fail(error.message); }
      try {
        const primary = rpmPrimaryRecord(repomd);
        const primaryPath = confinedRegularFile(architectureRoot, primary.location);
        if (!primaryPath || primary.checksumType !== 'sha256'
            || sha256File(primaryPath) !== primary.checksum
            || fs.statSync(primaryPath).size !== primary.size) {
          fail(`RPM repomd primary metadata is missing or checksum-invalid for ${architecture}`);
          continue;
        }
        const packages = rpmPrimaryPackages(primaryPath);
        const expected = (closure.packages ?? []).filter((row) => row.type === 'rpm' && row.architecture === architecture);
        if (packages.length !== expected.length) fail(`RPM primary metadata coverage mismatch for ${architecture}`);
        for (const record of expected) {
          const match = packages.find((item) => item.location === relativeUnix(architectureRoot, path.join(repositoryRoot, record.repository.file)));
          if (!match || match.name !== 'open-burn-bar' || match.version !== closure.version
              || match.architecture !== RPM_ARCHITECTURES[architecture]
              || match.checksumType !== 'sha256' || match.checksum !== record.repository.sha256
              || match.size !== record.repository.size) {
            fail(`RPM primary metadata does not bind ${record.repository.file}`);
          }
        }
      } catch (error) {
        fail(error.message);
      }
    }
  } finally {
    fs.rmSync(rpmDb, { recursive: true, force: true });
  }
}

function packageRecord(repositoryRoot, source, destination) {
  return {
    type: source.type,
    architecture: source.architecture,
    source: { file: source.file, sha256: source.sha256, size: source.size },
    repository: {
      file: relativeUnix(repositoryRoot, destination),
      sha256: sha256File(destination),
      size: fs.statSync(destination).size
    }
  };
}

function renderTemplate(repoRoot, templateRelative, destination, replacements) {
  const template = confinedRegularFile(repoRoot, templateRelative);
  if (!template) throw new Error(`repository template is missing or outside the repository: ${templateRelative}`);
  let value = fs.readFileSync(template, 'utf8');
  for (const [key, replacement] of Object.entries(replacements)) value = value.replaceAll(`{{${key}}}`, replacement);
  if (/\{\{[A-Z0-9_]+\}\}/u.test(value)) throw new Error(`repository template has unresolved placeholders: ${templateRelative}`);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, value);
}

function signDetached({ signingHome, fingerprint, input, output }) {
  runChecked('gpg', [
    '--homedir', signingHome, '--batch', '--yes', '--pinentry-mode', 'loopback', '--local-user', `${fingerprint}!`,
    '--digest-algo', 'SHA256', '--armor', '--detach-sign', '--output', output, input
  ]);
}

function verifyDetached(publicKeyPath, signature, input, expectedSigningFingerprint) {
  if (!signature || !input || !fs.existsSync(signature) || !fs.existsSync(input)) throw new Error('OpenPGP detached signature input is missing');
  withVerificationHome(publicKeyPath, (home) => {
    const result = runChecked('gpg', ['--homedir', home, '--batch', '--status-fd', '1', '--verify', signature, input]);
    requireValidSignatureFingerprint(result.stdout, expectedSigningFingerprint);
  });
}

function verifyClearSigned(publicKeyPath, input, expectedSigningFingerprint) {
  if (!input || !fs.existsSync(input)) throw new Error('OpenPGP clear-signed input is missing');
  withVerificationHome(publicKeyPath, (home) => {
    const result = runChecked('gpg', ['--homedir', home, '--batch', '--status-fd', '1', '--verify', input]);
    requireValidSignatureFingerprint(result.stdout, expectedSigningFingerprint);
  });
}

function requireValidSignatureFingerprint(statusOutput, expectedSigningFingerprint) {
  const fingerprints = String(statusOutput ?? '').split('\n')
    .map((line) => line.match(/^\[GNUPG:\]\s+VALIDSIG\s+([A-F0-9]{40,64})(?:\s|$)/u)?.[1])
    .filter(Boolean);
  if (fingerprints.length !== 1 || fingerprints[0] !== expectedSigningFingerprint) {
    throw new Error('OpenPGP signature does not match the pinned signing-subkey fingerprint');
  }
}

function withVerificationHome(publicKeyPath, body) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-repository-verify-'));
  fs.chmodSync(home, 0o700);
  try {
    runChecked('gpg', ['--homedir', home, '--batch', '--import', publicKeyPath]);
    return body(home);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}

function publicKeyMetadata(publicKeyPath, minimumValidUntilEpoch, expectedSigningFingerprint) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-public-key-'));
  fs.chmodSync(home, 0o700);
  try {
    runChecked('gpg', ['--homedir', home, '--batch', '--import', publicKeyPath]);
    return listedKeyMetadata(home, false, minimumValidUntilEpoch, expectedSigningFingerprint);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}

function secretSigningKey(home, minimumValidUntilEpoch, expectedSigningFingerprint) {
  return listedKeyMetadata(home, true, minimumValidUntilEpoch, expectedSigningFingerprint);
}

function listedKeyMetadata(home, secret, minimumValidUntilEpoch, expectedSigningFingerprint) {
  const result = runChecked('gpg', [
    '--homedir', home,
    '--batch',
    '--with-colons',
    '--with-fingerprint',
    '--with-subkey-fingerprint',
    secret ? '--list-secret-keys' : '--list-keys'
  ]);
  return selectOpenPgpSigningKey(result.stdout, minimumValidUntilEpoch, expectedSigningFingerprint);
}

function validateOpenPgpKey(key, minimumValidUntilEpoch, label) {
  if (!key.fingerprint) throw new Error(`repository ${label} key has no full fingerprint`);
  if (['r', 'e', 'd'].includes(key.validity)) throw new Error(`repository ${label} key is revoked, expired, or disabled`);
  if (!Number.isFinite(key.createdAt) || key.createdAt <= 0 || key.createdAt > Date.now() / 1000 + 300) {
    throw new Error(`repository ${label} key creation time is invalid`);
  }
  if (!Number.isFinite(key.expiresAt) || key.expiresAt <= minimumValidUntilEpoch) {
    throw new Error(`repository ${label} key does not meet the minimum remaining-validity policy`);
  }
  openPgpAlgorithm(key);
}

function openPgpAlgorithm(key) {
  if (key.algorithmId === 22) return 'EdDSA';
  if (key.algorithmId === 19) return 'ECDSA';
  if ([1, 2, 3].includes(key.algorithmId) && key.bits >= 3072) return 'RSA-3072+';
  throw new Error(`repository signing key algorithm is not allowed: algorithm=${key.algorithmId}, bits=${key.bits}`);
}

function rpmIdentity(file) {
  const fields = runChecked('rpm', [
    '-qp', '--qf', '%{NAME}\n%{VERSION}\n%{ARCH}\n%{SHA256HEADER}\n%{PAYLOADDIGEST}', file
  ]).stdout.trim().split('\n');
  if (fields.length !== 5 || fields.some((field) => !field || field === '(none)')) throw new Error(`RPM identity is incomplete: ${file}`);
  return {
    name: fields[0],
    version: fields[1],
    architecture: fields[2],
    headerDigest: fields[3],
    payloadDigest: fields[4]
  };
}

function rpmPrimaryRecord(repomd) {
  const script = String.raw`
import json, sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
def local(tag): return tag.rsplit('}', 1)[-1]
primary = next((item for item in root.iter() if local(item.tag) == 'data' and item.attrib.get('type') == 'primary'), None)
if primary is None: raise SystemExit('repomd has no primary data')
def child(name): return next((item for item in primary if local(item.tag) == name), None)
checksum = child('checksum'); location = child('location'); size = child('size')
if checksum is None or location is None or size is None: raise SystemExit('repomd primary record is incomplete')
print(json.dumps({'checksumType': checksum.attrib.get('type'), 'checksum': checksum.text, 'location': location.attrib.get('href'), 'size': int(size.text)}))
`;
  return JSON.parse(runChecked('python3', ['-c', script, repomd]).stdout);
}

function rpmPrimaryPackages(primaryPath) {
  const script = String.raw`
import gzip, json, sys, xml.etree.ElementTree as ET
with gzip.open(sys.argv[1], 'rb') as handle: root = ET.parse(handle).getroot()
def local(tag): return tag.rsplit('}', 1)[-1]
rows = []
for package in [item for item in root if local(item.tag) == 'package']:
    children = {local(item.tag): item for item in package}
    version = children.get('version'); checksum = children.get('checksum'); location = children.get('location'); size = children.get('size')
    rows.append({'name': children.get('name').text, 'architecture': children.get('arch').text,
      'version': version.attrib.get('ver'), 'checksumType': checksum.attrib.get('type'), 'checksum': checksum.text,
      'location': location.attrib.get('href'), 'size': int(size.attrib.get('package'))})
print(json.dumps(rows))
`;
  return JSON.parse(runChecked('python3', ['-c', script, primaryPath]).stdout);
}

function gitCommitEpoch(commit) {
  const value = runChecked('git', ['show', '-s', '--format=%ct', commit]).stdout.trim();
  if (!/^[1-9][0-9]*$/.test(value)) throw new Error('release commit timestamp is invalid');
  return Number(value);
}

function collectFiles(root, excluded = new Set(), ignore = () => false) {
  if (!fs.existsSync(root)) return [];
  const files = [];
  const walk = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(directory, entry.name);
      const relative = relativeUnix(root, full);
      if (entry.isSymbolicLink()) throw new Error(`repository output contains a symlink: ${relative}`);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && !excluded.has(relative) && !ignore(relative)) {
        files.push({ file: relative, sha256: sha256File(full), size: fs.statSync(full).size });
      } else if (!entry.isFile()) throw new Error(`repository output contains an unsupported entry: ${relative}`);
    }
  };
  walk(root);
  return files;
}

function parseControlParagraph(value) {
  return Object.fromEntries(value.split('\n').map((line) => {
    const separator = line.indexOf(':');
    return separator > 0 ? [line.slice(0, separator), line.slice(separator + 1).trim()] : [line, ''];
  }));
}

function readJson(file, label) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (error) { throw new Error(`${label} is missing or invalid JSON: ${error.message}`); }
}

function requireVersionAndChannel(version, channel) {
  if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(version ?? '')) throw new Error('repository version must be strict X.Y.Z semver');
  if (!SUPPORTED_CHANNELS.has(channel)) throw new Error('repository channel must be stable, prerelease, or nightly');
}

function confinedRegularFile(root, relative) {
  if (!fs.existsSync(root) || typeof relative !== 'string' || !relative || path.isAbsolute(relative)) return null;
  const resolvedRoot = fs.realpathSync(root);
  const lexical = path.resolve(resolvedRoot, relative);
  if (lexical !== resolvedRoot && !lexical.startsWith(`${resolvedRoot}${path.sep}`)) return null;
  if (!fs.existsSync(lexical)) return null;
  const real = fs.realpathSync(lexical);
  return (real === resolvedRoot || real.startsWith(`${resolvedRoot}${path.sep}`)) && fs.statSync(real).isFile() ? real : null;
}

function relativeUnix(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function commandPath(command) {
  const result = spawnSync('sh', ['-c', 'command -v "$1"', 'sh', command], { encoding: 'utf8' });
  if (result.status !== 0 || !result.stdout.trim()) throw new Error(`required repository tool is unavailable: ${command}`);
  return result.stdout.trim();
}

function runChecked(command, args, options = {}) {
  const env = {
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    LANG: 'C.UTF-8',
    LC_ALL: 'C.UTF-8',
    TZ: 'UTC',
    ...options.env
  };
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024
  });
  if (result.status !== 0) {
    const redactedArgs = args.map((arg) => options.secretPaths?.includes(arg) ? '<redacted-key-file>' : arg);
    throw new Error(`${command} ${redactedArgs.join(' ')} failed (${result.status ?? 'spawn'}): ${(result.stderr || result.error?.message || '').trim()}`);
  }
  return { stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}
