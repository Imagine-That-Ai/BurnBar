import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';
import {
  buildLinuxRepositories,
  hasTrustedRpmSignatureOutput,
  packageSetRoot,
  refreshLinuxRepositoryMetadata,
  selectOpenPgpSigningKey,
  sha256File,
  validateDistributionChannels,
  verifyLinuxRepositories,
  verifyRepositorySnapshot
} from './lib/linux-repository.mjs';

const VERSION = '1.2.3';
const CHANNEL = 'prerelease';
const COMMIT = '0123456789abcdef0123456789abcdef01234567';
const FINGERPRINT = '0123456789ABCDEF0123456789ABCDEF01234567';
const sourceRepoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

test('repository Worker pins the release-manifest Ed25519 feed identity exactly', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(sourceRepoRoot, 'packaging/linux/release-manifest.json'), 'utf8'));
  const publicKeyPath = path.join(sourceRepoRoot, manifest.signing.publicKey);
  const spki = crypto.createPublicKey(fs.readFileSync(publicKeyPath)).export({ type: 'spki', format: 'der' });
  const fingerprint = crypto.createHash('sha256').update(spki).digest('hex');
  const worker = fs.readFileSync(path.join(sourceRepoRoot, 'workers/linux-repository-router/src/index.mjs'), 'utf8');
  const bundledSpki = worker.match(/OFFICIAL_FEED_PUBLIC_KEY_SPKI_BASE64 = '([^']+)'/u)?.[1];
  const bundledFingerprint = worker.match(/OFFICIAL_FEED_PUBLIC_KEY_SPKI_SHA256 = '([a-f0-9]{64})'/u)?.[1];
  assert.equal(fingerprint, manifest.signing.publicKeySpkiSha256);
  assert.equal(bundledSpki, spki.toString('base64'));
  assert.equal(bundledFingerprint, fingerprint);
});

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-repository-test-'));
  const releaseOut = path.join(root, 'release');
  const artifacts = path.join(releaseOut, 'artifacts');
  const packaging = path.join(root, 'packaging');
  const bin = path.join(root, 'bin');
  fs.mkdirSync(artifacts, { recursive: true });
  fs.mkdirSync(packaging, { recursive: true });
  fs.mkdirSync(bin, { recursive: true });
  const rows = [];
  for (const [architecture, debArchitecture] of [['aarch64', 'arm64'], ['x86_64', 'amd64']]) {
    for (const [type, filename] of [
      ['deb', `OpenBurnBar_${VERSION}_${debArchitecture}.deb`],
      ['rpm', `OpenBurnBar-${VERSION}-1.${architecture}.rpm`]
    ]) {
      const full = path.join(artifacts, filename);
      fs.writeFileSync(full, `${type}:${architecture}:${VERSION}\n`);
      rows.push({
        type,
        architecture,
        file: `release/artifacts/${filename}`,
        sha256: sha256File(full),
        size: fs.statSync(full).size
      });
    }
  }
  fs.writeFileSync(path.join(releaseOut, 'package-closure.json'), `${JSON.stringify({
    schemaVersion: 3,
    generatedAt: new Date().toISOString(),
    version: VERSION,
    tag: `linux-v${VERSION}`,
    git: { commit: COMMIT },
    artifacts: rows
  })}\n`);
  const publicKey = path.join(packaging, 'repository-public-key.asc');
  fs.writeFileSync(publicKey, 'fake-public-key\n');
  const aptTemplate = path.join(packaging, 'openburnbar.sources.template');
  const rpmTemplate = path.join(packaging, 'openburnbar.repo.template');
  fs.writeFileSync(aptTemplate, 'URIs: {{APT_BASE_URL}}\nSuites: {{CHANNEL}}\nComponents: {{APT_COMPONENT}}\nSigned-By: {{APT_INSTALLED_KEYRING}}\n');
  fs.writeFileSync(rpmTemplate, '[{{RPM_REPOSITORY_ID}}]\nname={{RPM_REPOSITORY_NAME}}\nbaseurl={{RPM_BASE_URL}}/{{CHANNEL}}/$basearch\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=file://{{RPM_INSTALLED_KEY}}\n');
  const config = {
    schemaVersion: 1,
    repositoryMetadata: {
      aptValidForHours: 168,
      signingKeyMinimumRemainingDays: 30,
      refreshCheckIntervalHours: 6,
      refreshWhenRemainingHours: 96,
      criticalRemainingHours: 48,
      activationMinimumRemainingHours: 24
    },
    apt: {
      status: 'source-ready',
      baseUrl: 'https://downloads.burnbar.ai/linux/apt',
      origin: 'OpenBurnBar',
      label: 'OpenBurnBar Linux',
      component: 'main',
      architectures: { aarch64: 'arm64', x86_64: 'amd64' },
      sourcesTemplate: path.relative(root, aptTemplate),
      installedKeyring: '/usr/share/keyrings/openburnbar-archive-keyring.gpg'
    },
    rpm: {
      status: 'source-ready',
      baseUrl: 'https://downloads.burnbar.ai/linux/rpm',
      repositoryId: 'openburnbar',
      repositoryName: 'OpenBurnBar Linux',
      architectures: { aarch64: 'aarch64', x86_64: 'x86_64' },
      repoTemplate: path.relative(root, rpmTemplate),
      installedKey: '/etc/pki/rpm-gpg/RPM-GPG-KEY-openburnbar'
    },
    signing: {
      status: 'configured',
      publicKey: path.relative(root, publicKey),
      fingerprint: FINGERPRINT,
      signingFingerprint: FINGERPRINT,
      provisioning: 'complete'
    }
  };
  const configPath = path.join(packaging, 'distribution-channels.json');
  fs.writeFileSync(configPath, `${JSON.stringify(config)}\n`);
  installFakeTools(bin);
  return { root, releaseOut, rows, config, configPath, bin };
}

test('configuration accepts explicit unconfigured state but rejects placeholders', () => {
  const value = fixture();
  value.config.signing = {
    status: 'unconfigured', publicKey: null, fingerprint: null, signingFingerprint: null, provisioning: 'required'
  };
  assert.deepEqual(validateDistributionChannels(value.config), []);
  value.config.signing.fingerprint = 'REPLACE_ME';
  assert.ok(validateDistributionChannels(value.config).some((failure) => /unconfigured signing/u.test(failure)));
  value.config.signing.fingerprint = null;
  value.config.repositoryMetadata.refreshWhenRemainingHours = 72;
  assert.ok(validateDistributionChannels(value.config).some((failure) => /refreshWhenRemainingHours must be 96/u.test(failure)));
  fs.rmSync(value.root, { recursive: true, force: true });
});

test('package-set root is stable by identity and changes on hash mutation', () => {
  const value = fixture();
  const left = packageSetRoot(value.rows);
  const right = packageSetRoot([...value.rows].reverse());
  assert.equal(left, right);
  assert.notEqual(packageSetRoot(value.rows.map((row, index) => index === 0 ? { ...row, sha256: 'f'.repeat(64) } : row)), left);
  fs.rmSync(value.root, { recursive: true, force: true });
});

test('RPM signature verification rejects digest-only, unsigned, unknown-key, and wrong-key output', () => {
  const trusted = 'openburnbar.rpm: digests signatures OK, key ID 01234567';
  assert.equal(hasTrustedRpmSignatureOutput(trusted, FINGERPRINT), true);
  assert.equal(hasTrustedRpmSignatureOutput('openburnbar.rpm: digests OK', FINGERPRINT), false);
  assert.equal(hasTrustedRpmSignatureOutput(`${trusted} (NOKEY)`, FINGERPRINT), false);
  assert.equal(hasTrustedRpmSignatureOutput('openburnbar.rpm: digests signatures NOT OK, key ID 01234567', FINGERPRINT), false);
  assert.equal(hasTrustedRpmSignatureOutput(trusted, 'A'.repeat(40)), false);
});

test('OpenPGP policy selects a capable long-lived subkey and rejects weak or near-expiry keys', () => {
  const primary = `sec:u:4096:1:ABCDEF01:1710000000:4102444800:::::c:\nfpr:::::::::${FINGERPRINT}:`;
  const subkeyFingerprint = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01';
  const subkey = `ssb:u:255:22:ABCDEF02:1710000000:4102444800:::::s:\nfpr:::::::::${subkeyFingerprint}:`;
  assert.deepEqual(selectOpenPgpSigningKey(`${primary}\n${subkey}\n`, 2000000000), {
    primaryFingerprint: FINGERPRINT,
    signingFingerprint: subkeyFingerprint,
    signingAlgorithm: 'EdDSA',
    signingKeyExpiresAt: 4102444800
  });
  assert.throws(
    () => selectOpenPgpSigningKey(`${primary}\n${subkey.replace('4102444800', '1900000000')}\n`, 2000000000),
    /minimum remaining-validity/u
  );
  assert.throws(
    () => selectOpenPgpSigningKey(`${primary}\n${subkey.replace('ssb:u:', 'ssb:r:')}\n`, 2000000000),
    /no usable signing key/u
  );
  assert.throws(
    () => selectOpenPgpSigningKey(primary.replace(':4096:1:', ':2048:1:'), 2000000000),
    /algorithm is not allowed/u
  );
});

test('builder and verifier bind apt/RPM metadata, signatures, architectures, and release packages', () => {
  const value = fixture();
  const previousPath = process.env.PATH;
  process.env.PATH = `${value.bin}:${previousPath}`;
  try {
    const built = buildLinuxRepositories({
      repoRoot: value.root,
      releaseOut: value.releaseOut,
      configPath: value.configPath,
      version: VERSION,
      channel: CHANNEL,
      privateKeyBytes: Buffer.from('fake-private-key')
    });
    assert.equal(built.closure.packages.length, 4);
    assert.equal(built.closure.files.some((row) => row.file.endsWith('/InRelease')), true);
    assert.equal(built.closure.files.filter((row) => row.file.endsWith('/repomd.xml.asc')).length, 2);
    assert.equal(fs.existsSync(path.join(built.repositoryRoot, `apt/openburnbar-${CHANNEL}.sources`)), true);
    assert.equal(fs.existsSync(path.join(built.repositoryRoot, `rpm/openburnbar-${CHANNEL}.repo`)), true);
    assert.equal(fs.existsSync(path.join(built.repositoryRoot, 'apt/openburnbar.sources')), false);
    assert.equal(built.closure.files.some((row) => row.file.includes('/by-hash/SHA256/')), true);
    const verified = verifyLinuxRepositories({
      repoRoot: value.root,
      releaseOut: value.releaseOut,
      configPath: value.configPath,
      version: VERSION,
      channel: CHANNEL
    });
    assert.deepEqual(verified.failures, []);
    assert.equal(verified.passed, true);
  } finally {
    process.env.PATH = previousPath;
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('verifier rejects metadata mutation, source drift, path traversal, and stale channel', () => {
  const scenarios = [
    {
      name: 'metadata mutation',
      mutate(value) {
        fs.appendFileSync(path.join(value.releaseOut, 'repositories/apt/dists/prerelease/Release'), 'tampered\n');
      },
      expected: /repository file drifted|signature/u
    },
    {
      name: 'source drift',
      mutate(value) {
        fs.appendFileSync(path.join(value.root, value.rows[0].file), 'tampered\n');
      },
      expected: /package artifact drifted/u
    },
    {
      name: 'path traversal',
      mutate(value) {
        const closurePath = path.join(value.releaseOut, 'repositories/repository-closure.json');
        const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
        closure.files[0].file = '../outside';
        fs.writeFileSync(closurePath, `${JSON.stringify(closure)}\n`);
      },
      expected: /outside output|signature/u
    },
    {
      name: 'stale channel',
      mutate(value) {
        const closurePath = path.join(value.releaseOut, 'repositories/repository-closure.json');
        const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
        closure.channel = 'stable';
        fs.writeFileSync(closurePath, `${JSON.stringify(closure)}\n`);
      },
      expected: /version\/channel mismatch|signature/u
    },
    {
      name: 'public fingerprint drift',
      mutate(value) {
        value.config.signing.fingerprint = 'B'.repeat(40);
        fs.writeFileSync(value.configPath, `${JSON.stringify(value.config)}\n`);
      },
      expected: /fingerprint/u
    },
    {
      name: 'signature subkey drift',
      mutate(value) {
        const gpg = path.join(value.bin, 'gpg');
        const source = fs.readFileSync(gpg, 'utf8');
        fs.writeFileSync(gpg, source.replace(
          `[GNUPG:] VALIDSIG ${FINGERPRINT}`,
          `[GNUPG:] VALIDSIG ${'B'.repeat(40)}`
        ), { mode: 0o755 });
      },
      expected: /pinned signing-subkey fingerprint/u
    },
    {
      name: 'apt signed graph drift',
      mutate(value) {
        const relative = 'apt/dists/prerelease/main/binary-amd64/Packages';
        const full = path.join(value.releaseOut, 'repositories', relative);
        fs.appendFileSync(full, 'Package: injected\\n');
        rebindRepositoryFile(value, relative);
      },
      expected: /apt Release does not bind/u
    },
    {
      name: 'apt missing expiry',
      mutate(value) {
        const relative = 'apt/dists/prerelease/Release';
        const full = path.join(value.releaseOut, 'repositories', relative);
        fs.writeFileSync(full, fs.readFileSync(full, 'utf8').replace(/^Valid-Until:.*\n/mu, ''));
        rebindRepositoryFile(value, relative);
      },
      expected: /Valid-Until/u
    },
    {
      name: 'apt excessive expiry horizon',
      mutate(value) {
        const relative = 'apt/dists/prerelease/Release';
        const full = path.join(value.releaseOut, 'repositories', relative);
        const release = fs.readFileSync(full, 'utf8');
        const current = release.match(/^Valid-Until:\s*(.+)$/mu)?.[1];
        const excessive = new Date(Date.parse(current) + 60 * 60 * 1000).toUTCString();
        fs.writeFileSync(full, release.replace(/^Valid-Until:.*$/mu, `Valid-Until: ${excessive}`));
        const closurePath = path.join(value.releaseOut, 'repositories/repository-closure.json');
        const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
        closure.repositories.apt.validUntil = new Date(excessive).toISOString();
        fs.writeFileSync(closurePath, `${JSON.stringify(closure)}\n`);
        rebindRepositoryFile(value, relative);
      },
      expected: /exactly 168 hours/u
    },
    {
      name: 'apt expired metadata',
      mutate(value) {
        const relative = 'apt/dists/prerelease/Release';
        const full = path.join(value.releaseOut, 'repositories', relative);
        const releaseDate = new Date(Date.now() - 9 * 24 * 60 * 60 * 1000);
        const validUntil = new Date(releaseDate.getTime() + 7 * 24 * 60 * 60 * 1000);
        let release = fs.readFileSync(full, 'utf8');
        release = release.replace(/^Date:.*$/mu, `Date: ${releaseDate.toUTCString()}`);
        release = release.replace(/^Valid-Until:.*$/mu, `Valid-Until: ${validUntil.toUTCString()}`);
        fs.writeFileSync(full, release);
        const closurePath = path.join(value.releaseOut, 'repositories/repository-closure.json');
        const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
        closure.repositories.apt.releaseDate = new Date(Math.floor(releaseDate.getTime() / 1000) * 1000).toISOString();
        closure.repositories.apt.validUntil = new Date(Math.floor(validUntil.getTime() / 1000) * 1000).toISOString();
        fs.writeFileSync(closurePath, `${JSON.stringify(closure)}\n`);
        rebindRepositoryFile(value, relative);
      },
      expected: /metadata is expired/u
    },
    {
      name: 'RPM signed graph drift',
      mutate(value) {
        const closurePath = path.join(value.releaseOut, 'repositories/repository-closure.json');
        const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
        const record = closure.files.find((row) => row.file.endsWith('-primary.xml.gz'));
        const full = path.join(value.releaseOut, 'repositories', record.file);
        const xml = zlib.gunzipSync(fs.readFileSync(full)).toString('utf8').replace('open-burn-bar', 'other-package');
        fs.writeFileSync(full, zlib.gzipSync(Buffer.from(xml)));
        rebindRepositoryFile(value, record.file);
      },
      expected: /RPM repomd primary metadata/u
    },
    {
      name: 'RPM immutable header drift',
      mutate(value) {
        const rpm = path.join(value.bin, 'rpm');
        const source = fs.readFileSync(rpm, 'utf8');
        fs.writeFileSync(rpm, source.replace(
          "process.stdout.write('open-burn-bar\\n1.2.3\\n' + architecture + '\\nheader-digest\\npayload-digest');",
          "process.stdout.write('open-burn-bar\\n1.2.3\\n' + architecture + '\\n' + (file.includes('/repositories/') ? 'changed-header' : 'header-digest') + '\\npayload-digest');"
        ), { mode: 0o755 });
      },
      expected: /RPM identity or payload differs/u
    }
  ];
  const previousPath = process.env.PATH;
  for (const scenario of scenarios) {
    const value = fixture();
    process.env.PATH = `${value.bin}:${previousPath}`;
    try {
      buildLinuxRepositories({
        repoRoot: value.root,
        releaseOut: value.releaseOut,
        configPath: value.configPath,
        version: VERSION,
        channel: CHANNEL,
        privateKeyBytes: Buffer.from('fake-private-key')
      });
      scenario.mutate(value);
      const result = verifyLinuxRepositories({
        repoRoot: value.root,
        releaseOut: value.releaseOut,
        configPath: value.configPath,
        version: VERSION,
        channel: CHANNEL
      });
      assert.equal(result.passed, false, scenario.name);
      assert.match(result.failures.join('\n'), scenario.expected, scenario.name);
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
  process.env.PATH = previousPath;
});

test('failed rebuild preserves the last complete repository and removes staging output', () => {
  const value = fixture();
  const previousPath = process.env.PATH;
  process.env.PATH = `${value.bin}:${previousPath}`;
  try {
    const first = buildLinuxRepositories({
      repoRoot: value.root,
      releaseOut: value.releaseOut,
      configPath: value.configPath,
      version: VERSION,
      channel: CHANNEL,
      privateKeyBytes: Buffer.from('fake-private-key')
    });
    const before = fs.readFileSync(first.closurePath);
    value.config.signing.fingerprint = 'B'.repeat(40);
    fs.writeFileSync(value.configPath, `${JSON.stringify(value.config)}\n`);
    assert.throws(() => buildLinuxRepositories({
      repoRoot: value.root,
      releaseOut: value.releaseOut,
      configPath: value.configPath,
      version: VERSION,
      channel: CHANNEL,
      privateKeyBytes: Buffer.from('fake-private-key')
    }), /fingerprint/u);
    assert.deepEqual(fs.readFileSync(first.closurePath), before);
    assert.equal(fs.readdirSync(value.releaseOut).some((name) => name.startsWith('.repositories-staging-')), false);
  } finally {
    process.env.PATH = previousPath;
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('metadata refresh advances only signed apt expiry roots and chains to exact immutable parent bytes', () => {
  const value = fixture();
  const previousPath = process.env.PATH;
  process.env.PATH = `${value.bin}:${previousPath}`;
  try {
    const parent = buildLinuxRepositories({
      repoRoot: value.root,
      releaseOut: value.releaseOut,
      configPath: value.configPath,
      version: VERSION,
      channel: CHANNEL,
      privateKeyBytes: Buffer.from('fake-private-key')
    });
    const parentBytes = fs.readFileSync(parent.closurePath);
    const parentId = crypto.createHash('sha256').update(parentBytes).digest('hex');
    const immutableBefore = new Map(parent.closure.files
      .filter((row) => ![
        `apt/dists/${CHANNEL}/Release`,
        `apt/dists/${CHANNEL}/InRelease`,
        `apt/dists/${CHANNEL}/Release.gpg`
      ].includes(row.file))
      .map((row) => [row.file, row]));
    fs.writeFileSync(path.join(value.bin, 'rpmsign'), `#!${process.execPath}\nprocess.exit(91);\n`, { mode: 0o755 });
    const parentEpoch = Date.parse(parent.closure.repositories.apt.releaseDate) / 1000;
    const refreshEpoch = parentEpoch + 1;
    const output = path.join(value.root, 'refreshed-repository');
    const refreshed = refreshLinuxRepositoryMetadata({
      repoRoot: value.root,
      sourceRepositoryRoot: parent.repositoryRoot,
      outputRepositoryRoot: output,
      configPath: value.configPath,
      privateKeyBytes: Buffer.from('fake-private-key'),
      refreshEpoch,
      nowEpoch: refreshEpoch
    });
    assert.equal(refreshed.closure.schemaVersion, 2);
    assert.deepEqual(refreshed.closure.refresh, {
      kind: 'apt-expiry',
      refreshedAt: new Date(refreshEpoch * 1000).toISOString(),
      previousSnapshotId: parentId,
      previousReleaseDate: parent.closure.repositories.apt.releaseDate,
      previousValidUntil: parent.closure.repositories.apt.validUntil
    });
    assert.equal(Date.parse(refreshed.closure.repositories.apt.validUntil)
      - Date.parse(refreshed.closure.repositories.apt.releaseDate), 168 * 60 * 60 * 1000);
    assert.deepEqual(refreshed.closure.packages, parent.closure.packages);
    assert.deepEqual(refreshed.closure.repositories.rpm, parent.closure.repositories.rpm);
    for (const [file, record] of immutableBefore) {
      const next = refreshed.closure.files.find((row) => row.file === file);
      assert.deepEqual(next, record, file);
      assert.deepEqual(fs.readFileSync(path.join(output, file)), fs.readFileSync(path.join(parent.repositoryRoot, file)), file);
    }
    assert.equal(verifyRepositorySnapshot({
      repoRoot: value.root,
      repositoryRoot: output,
      configPath: value.configPath,
      version: VERSION,
      channel: CHANNEL
    }).passed, true);

    const retryOutput = path.join(value.root, 'refreshed-repository-retry');
    const retry = refreshLinuxRepositoryMetadata({
      repoRoot: value.root,
      sourceRepositoryRoot: parent.repositoryRoot,
      outputRepositoryRoot: retryOutput,
      configPath: value.configPath,
      privateKeyBytes: Buffer.from('fake-private-key'),
      refreshEpoch,
      nowEpoch: refreshEpoch
    });
    assert.deepEqual(fs.readFileSync(retry.closurePath), fs.readFileSync(refreshed.closurePath));
    assert.equal(retry.snapshotId, refreshed.snapshotId);
  } finally {
    process.env.PATH = previousPath;
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('metadata refresh rejects parent drift, nonadvancing windows, clock skew, and preserves prior output on failure', () => {
  const value = fixture();
  const previousPath = process.env.PATH;
  process.env.PATH = `${value.bin}:${previousPath}`;
  try {
    const parent = buildLinuxRepositories({
      repoRoot: value.root,
      releaseOut: value.releaseOut,
      configPath: value.configPath,
      version: VERSION,
      channel: CHANNEL,
      privateKeyBytes: Buffer.from('fake-private-key')
    });
    const parentEpoch = Date.parse(parent.closure.repositories.apt.releaseDate) / 1000;
    const output = path.join(value.root, 'refresh-output');
    fs.mkdirSync(output);
    fs.writeFileSync(path.join(output, 'sentinel'), 'preserve\n');
    assert.throws(() => refreshLinuxRepositoryMetadata({
      repoRoot: value.root,
      sourceRepositoryRoot: parent.repositoryRoot,
      outputRepositoryRoot: parent.repositoryRoot,
      configPath: value.configPath,
      privateKeyBytes: Buffer.from('fake-private-key'),
      refreshEpoch: parentEpoch + 1,
      nowEpoch: parentEpoch + 1
    }), /separate sibling tree/u);
    assert.throws(() => refreshLinuxRepositoryMetadata({
      repoRoot: value.root,
      sourceRepositoryRoot: parent.repositoryRoot,
      outputRepositoryRoot: output,
      configPath: value.configPath,
      privateKeyBytes: Buffer.from('fake-private-key'),
      refreshEpoch: parentEpoch,
      nowEpoch: parentEpoch
    }), /advance beyond/u);
    assert.equal(fs.readFileSync(path.join(output, 'sentinel'), 'utf8'), 'preserve\n');
    assert.throws(() => refreshLinuxRepositoryMetadata({
      repoRoot: value.root,
      sourceRepositoryRoot: parent.repositoryRoot,
      outputRepositoryRoot: output,
      configPath: value.configPath,
      privateKeyBytes: Buffer.from('fake-private-key'),
      refreshEpoch: parentEpoch + 360,
      nowEpoch: parentEpoch
    }), /five minutes/u);
    const packageRecord = parent.closure.files.find((row) => row.file.endsWith('.rpm'));
    fs.appendFileSync(path.join(parent.repositoryRoot, packageRecord.file), 'drift');
    assert.throws(() => refreshLinuxRepositoryMetadata({
      repoRoot: value.root,
      sourceRepositoryRoot: parent.repositoryRoot,
      outputRepositoryRoot: output,
      configPath: value.configPath,
      privateKeyBytes: Buffer.from('fake-private-key'),
      refreshEpoch: parentEpoch + 1,
      nowEpoch: parentEpoch + 1
    }), /parent repository verification failed/u);
    assert.equal(fs.readFileSync(path.join(output, 'sentinel'), 'utf8'), 'preserve\n');
  } finally {
    process.env.PATH = previousPath;
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('builder rejects a package closure generated beyond the five-minute clock-skew allowance', () => {
  const value = fixture();
  const closurePath = path.join(value.releaseOut, 'package-closure.json');
  const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
  closure.generatedAt = new Date(Date.now() + 6 * 60 * 1000).toISOString();
  fs.writeFileSync(closurePath, `${JSON.stringify(closure)}\n`);
  assert.throws(() => buildLinuxRepositories({
    repoRoot: value.root,
    releaseOut: value.releaseOut,
    configPath: value.configPath,
    version: VERSION,
    channel: CHANNEL,
    privateKeyBytes: Buffer.from('fake-private-key')
  }), /future-skew/u);
  fs.rmSync(value.root, { recursive: true, force: true });
});

test('release workflow preserves key custody, lifecycle, attestation, atomic activation, and feed order', () => {
  const workflow = fs.readFileSync(path.join(sourceRepoRoot, '.github/workflows/linux-release.yml'), 'utf8');
  const lifecycle = fs.readFileSync(path.join(sourceRepoRoot, 'scripts/linux-port/verify-linux-repository-lifecycle.sh'), 'utf8');
  const upload = fs.readFileSync(path.join(sourceRepoRoot, 'scripts/upload-linux-downloads-r2.sh'), 'utf8');
  const orderedWorkflowMarkers = [
    'Build signed apt and RPM repositories',
    'Verify signed apt and RPM repositories',
    'Enable cross-architecture repository clients',
    'Verify clean apt and dnf repository lifecycle',
    'Bind repository lifecycle into release closure',
    'Pre-attestation Linux release verification',
    'Attest Linux release sidecars and packages',
    'Final Linux release verification',
    'Provision branded Linux repository storage',
    'Publish immutable Linux release and repository snapshot',
    'Verify exact snapshot apt and dnf lifecycle before activation',
    'Atomically activate Linux repository snapshot',
    'Deploy branded Linux repository serving routes',
    'Verify active public Linux repository bytes',
    'Verify clean public apt and dnf repository lifecycle',
    'Drill repository rollback and candidate reactivation',
    'Atomically publish signed update feed pointer',
    'Deploy branded Linux update feed routes',
    'Verify signed update feed pointer and public bytes',
    'Verify live Linux update feed after publish',
    'Preserve and attest repository publication evidence',
    'Publish Linux GitHub release',
    'Remove partial draft GitHub release',
    'Compensate failed repository publication',
    'Enforce atomic repository publication outcome'
  ];
  let cursor = -1;
  for (const marker of orderedWorkflowMarkers) {
    const index = workflow.indexOf(marker);
    assert.ok(index > cursor, `workflow marker out of order: ${marker}`);
    cursor = index;
  }
  assert.match(workflow, /repository_signing_key=.*OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY/u);
  assert.match(workflow, /unset OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY/u);
  assert.match(workflow, /docker\/setup-qemu-action@[a-f0-9]{40}/u);
  for (const required of [
    'linux/amd64', 'linux/arm64', 'apt-get remove -y open-burn-bar',
    'dnf --assumeyes remove open-burn-bar', 'repo_gpgcheck=1', '@sha256:',
    'activeSnapshotId', 'transcriptSha256', 'lifecycle_mode', 'receipt_base_url',
    'OPENBURNBAR_LINUX_REPOSITORY_PREVIEW_SNAPSHOT', 'repository-preview/$channel/$preview_snapshot'
  ]) assert.ok(lifecycle.includes(required), required);
  assert.ok(upload.indexOf('for file in "${shared_repository_files[@]}"')
    < upload.indexOf('for file in "${repository_files[@]}"'));
  assert.doesNotMatch(upload, /put_object[^\n]*['"]latest-linux\.json['"]/u);
});

test('public lifecycle consumes canonical published onboarding while local mode keeps isolated fixtures', () => {
  const lifecycle = fs.readFileSync(
    path.join(sourceRepoRoot, 'scripts/linux-port/verify-linux-repository-lifecycle.sh'),
    'utf8'
  );

  for (const publishedPath of [
    'apt/openburnbar-archive-keyring.gpg',
    'apt/openburnbar-$channel-archive-keyring.gpg',
    'apt/openburnbar-$channel.sources',
    'rpm/RPM-GPG-KEY-openburnbar',
    'rpm/RPM-GPG-KEY-openburnbar-$channel',
    'rpm/openburnbar-$channel.repo'
  ]) assert.ok(lifecycle.includes(`$repository_base_url/${publishedPath}`), publishedPath);
  for (const publicInput of [
    '"$OPENBURNBAR_APT_KEY_URL" --output "$keyring"',
    '"$OPENBURNBAR_APT_SOURCES_URL" --output "$published_sources"',
    '"$OPENBURNBAR_RPM_KEY_URL" --output "$key"',
    '"$OPENBURNBAR_RPM_REPO_URL" --output "$published_repo"'
  ]) assert.ok(lifecycle.includes(publicInput), publicInput);

  assert.match(lifecycle, /gpg --batch --show-keys "\$keyring"/u);
  assert.match(lifecycle, /gpg --batch --show-keys "\$key"/u);
  assert.match(lifecycle, /cmp --silent \/tmp\/openburnbar\.expected\.sources "\$published_sources"/u);
  assert.match(lifecycle, /cmp --silent \/tmp\/openburnbar\.expected\.repo "\$published_repo"/u);
  assert.match(lifecycle, /mode === 'preview' \? 'preview-onboarding-with-synthesized-base'/u);
  assert.match(lifecycle, /onboarding: mode !== 'local'/u);
  assert.match(lifecycle, /previewSnapshotId: mode === 'preview' \? activeSnapshotId : null/u);
  assert.match(lifecycle, /sed "s\|URIs: \$OPENBURNBAR_CANONICAL_REPOSITORY_BASE_URL\/apt/u);
  assert.match(lifecycle, /sed "s\|baseurl=\$OPENBURNBAR_CANONICAL_REPOSITORY_BASE_URL\/rpm\//u);
  assert.ok(lifecycle.indexOf('closure_sha256="$(sha256sum')
    < lifecycle.indexOf('active_snapshot_id="$(curl --disable'));
  assert.match(lifecycle, /if \[\[ "\$active_snapshot_id" != "\$closure_sha256" \]\]/u);

  assert.match(lifecycle, /apt_mount_args=\(-v "\$repository_root\/apt\/openburnbar-archive-keyring\.gpg:/u);
  assert.match(lifecycle, /rpm_mount_args=\(-v "\$repository_root\/rpm\/RPM-GPG-KEY-openburnbar:/u);
  assert.match(lifecycle, /cp \/openburnbar-repository\.gpg \/etc\/apt\/keyrings\/openburnbar-repository\.gpg/u);
  assert.match(lifecycle, /gpgkey=file:\/\/\/openburnbar-rpm-key/u);
});

function installFakeTools(bin) {
  const write = (name, source) => fs.writeFileSync(path.join(bin, name), `#!${process.execPath}\n${source}\n`, { mode: 0o755 });
  write('gpg', `
const fs = require('node:fs');
const args = process.argv.slice(2);
if (args.includes('--with-colons')) {
  process.stdout.write((args.includes('--list-secret-keys') ? 'sec' : 'pub') + ':u:4096:1:ABCDEF01:1710000000:4102444800:::::sc:\\n' + 'fpr:::::::::${FINGERPRINT}:\\n');
} else if (args.includes('--verify')) {
  process.stdout.write('[GNUPG:] VALIDSIG ${FINGERPRINT} 2026-07-11 0 4 0 1 10 00 ${FINGERPRINT}\\n');
} else if (args.includes('--output')) {
  const output = args[args.indexOf('--output') + 1];
  fs.mkdirSync(require('node:path').dirname(output), { recursive: true });
  fs.writeFileSync(output, args.includes('--export') ? 'fake-public-key\\n' : 'fake-signature\\n');
}
`);
  write('git', `process.stdout.write('${COMMIT === '' ? '1' : '1710000000'}\\n');`);
  write('rpm', `
const file = process.argv[process.argv.length - 1];
const architecture = file.includes('aarch64') ? 'aarch64' : 'x86_64';
process.stdout.write('open-burn-bar\\n${VERSION}\\n' + architecture + '\\nheader-digest\\npayload-digest');
`);
  write('rpmsign', ``);
  write('rpmkeys', `if (process.argv.includes('--checksig')) process.stdout.write('package.rpm: digests signatures OK, key ID 01234567\\n');`);
  write('apt-ftparchive', `
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[process.argv.length - 1];
const option = (name) => process.argv.find((value) => value.startsWith(name + '='))?.slice(name.length + 1);
const files = [];
const walk = (directory) => {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.isFile()) files.push(full);
  }
};
walk(root);
process.stdout.write('Origin: OpenBurnBar\\nSuite: ${CHANNEL}\\nArchitectures: amd64 arm64\\nComponents: main\\nAcquire-By-Hash: yes\\nDate: ' + option('APT::FTPArchive::Release::Date') + '\\nValid-Until: ' + option('APT::FTPArchive::Release::Valid-Until') + '\\nSHA256:\\n');
for (const file of files.sort()) {
  const bytes = fs.readFileSync(file);
  process.stdout.write(' ' + crypto.createHash('sha256').update(bytes).digest('hex') + ' ' + bytes.length + ' ' + path.relative(root, file) + '\\n');
}
`);
  write('createrepo_c', `
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const directory = process.argv[process.argv.length - 1];
fs.mkdirSync(path.join(directory, 'repodata'), { recursive: true });
const packageName = fs.readdirSync(directory).find((name) => name.endsWith('.rpm'));
const packageBytes = fs.readFileSync(path.join(directory, packageName));
const architecture = packageName.includes('aarch64') ? 'aarch64' : 'x86_64';
const packageSha = crypto.createHash('sha256').update(packageBytes).digest('hex');
const primaryXml = '<metadata><package><name>open-burn-bar</name><arch>' + architecture + '</arch><version ver="${VERSION}"/><checksum type="sha256">' + packageSha + '</checksum><location href="' + packageName + '"/><size package="' + packageBytes.length + '"/></package></metadata>';
const primaryBytes = zlib.gzipSync(Buffer.from(primaryXml));
const primarySha = crypto.createHash('sha256').update(primaryBytes).digest('hex');
const primaryName = primarySha + '-primary.xml.gz';
fs.writeFileSync(path.join(directory, 'repodata', primaryName), primaryBytes);
fs.writeFileSync(path.join(directory, 'repodata/repomd.xml'), '<repomd><data type="primary"><checksum type="sha256">' + primarySha + '</checksum><location href="repodata/' + primaryName + '"/><size>' + primaryBytes.length + '</size></data></repomd>\\n');
`);
  write('dpkg-scanpackages', `
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const architecture = args[args.indexOf('--arch') + 1];
const directory = args[args.indexOf('--arch') + 2];
for (const name of fs.readdirSync(directory).sort()) {
  if ((architecture === 'amd64' && !name.endsWith('_amd64.deb')) || (architecture === 'arm64' && !name.endsWith('_arm64.deb'))) continue;
  const file = path.join(directory, name);
  const bytes = fs.readFileSync(file);
  process.stdout.write([
    'Package: open-burn-bar',
    'Version: ${VERSION}',
    'Architecture: ' + architecture,
    'Filename: ' + file,
    'Size: ' + bytes.length,
    'SHA256: ' + crypto.createHash('sha256').update(bytes).digest('hex'),
    '', ''
  ].join('\\n'));
}
`);
}

function rebindRepositoryFile(value, relative) {
  const closurePath = path.join(value.releaseOut, 'repositories/repository-closure.json');
  const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
  const record = closure.files.find((row) => row.file === relative);
  const full = path.join(value.releaseOut, 'repositories', relative);
  record.sha256 = sha256File(full);
  record.size = fs.statSync(full).size;
  fs.writeFileSync(closurePath, `${JSON.stringify(closure)}\n`);
}
