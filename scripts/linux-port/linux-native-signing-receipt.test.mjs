import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  canonicalJson,
  createNativePackageSigningReceipt,
  measureNativeSignerInputs,
  preparationReceiptDigest,
  signNativePackageSigningReceipt,
  validatePreparationForSigner,
  validateSignedPackageArtifacts,
  verifyNativePackageSigningReceipt
} from './lib/linux-native-signing-receipt.mjs';

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-receipt-'));
  fs.mkdirSync(path.join(root, 'target/runtime'), { recursive: true });
  fs.writeFileSync(path.join(root, 'target/gui'), 'gui', { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'target/runtime/lib.so'), 'runtime', { mode: 0o644 });
  fs.symlinkSync('lib.so', path.join(root, 'target/runtime/current'));
  return { root, inputs: ['target/gui', 'target/runtime'] };
}

function receiptOptions() {
  return {
    version: '1.2.3',
    architecture: 'x86_64',
    gitCommit: '01'.repeat(20),
    firebaseAppId: '1:123456789:web:linuxabcdef012345',
    preparationDigestSha256: '02'.repeat(32),
    signerInputsRootSha256: '03'.repeat(32),
    packages: [
      {
        type: 'rpm',
        file: 'bundle/OpenBurnBar.rpm',
        size: 12,
        sha256: '04'.repeat(32),
        installedManifestDigestSha256: '05'.repeat(32)
      },
      {
        type: 'deb',
        file: 'bundle/OpenBurnBar.deb',
        size: 10,
        sha256: '06'.repeat(32),
        installedManifestDigestSha256: '07'.repeat(32)
      }
    ]
  };
}

test('signer input measurement binds file bytes, modes, symlinks, and recursive tree entries', () => {
  const f = fixture();
  const initial = measureNativeSignerInputs(f.root, f.inputs);
  assert.deepEqual(initial.records.map((record) => record.path), [
    'target/gui',
    'target/runtime',
    'target/runtime/current',
    'target/runtime/lib.so'
  ]);

  fs.appendFileSync(path.join(f.root, 'target/gui'), '-mutated');
  assert.notEqual(measureNativeSignerInputs(f.root, f.inputs).rootSha256, initial.rootSha256);
  fs.writeFileSync(path.join(f.root, 'target/gui'), 'gui', { mode: 0o755 });
  fs.chmodSync(path.join(f.root, 'target/runtime/lib.so'), 0o600);
  assert.notEqual(measureNativeSignerInputs(f.root, f.inputs).rootSha256, initial.rootSha256);
  fs.rmSync(f.root, { recursive: true, force: true });
});

test('signer input measurement rejects missing inputs and symlinks escaping the repository', () => {
  const f = fixture();
  assert.throws(() => measureNativeSignerInputs(f.root, ['missing']), /required native signer input is missing/);
  fs.symlinkSync('../../outside', path.join(f.root, 'target/escape'));
  assert.throws(() => measureNativeSignerInputs(f.root, ['target/escape']), /escapes repository root/);
  fs.rmSync(f.root, { recursive: true, force: true });
});

test('preparation validation binds commit, version, architecture, and measured signer inputs', () => {
  const receipt = {
    schemaVersion: 1,
    complete: true,
    version: '1.2.3',
    architecture: 'x86_64',
    gitCommit: '01'.repeat(20),
    signerInputsRootSha256: '02'.repeat(32)
  };
  const digest = validatePreparationForSigner({
    receipt,
    version: receipt.version,
    architecture: receipt.architecture,
    gitCommit: receipt.gitCommit,
    signerInputsRootSha256: receipt.signerInputsRootSha256
  });
  assert.equal(digest, preparationReceiptDigest(receipt));
  assert.throws(() => validatePreparationForSigner({
    receipt: null,
    version: receipt.version,
    architecture: receipt.architecture,
    gitCommit: receipt.gitCommit,
    signerInputsRootSha256: receipt.signerInputsRootSha256
  }), /do not match/);
  assert.throws(() => validatePreparationForSigner({
    receipt,
    version: receipt.version,
    architecture: receipt.architecture,
    gitCommit: receipt.gitCommit,
    signerInputsRootSha256: 'ff'.repeat(32)
  }), /do not match/);
});

test('every generated native package input class is bound by the preparation root', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-input-classes-'));
  const inputs = [
    'target/release/openburnbar-linux-desktop',
    'target/payload/openburnbar-daemon',
    'target/payload/swift',
    'target/payload/native'
  ];
  for (const input of inputs) {
    const absolute = path.join(root, input);
    if (path.extname(input) || input.endsWith('openburnbar-daemon')) {
      fs.mkdirSync(path.dirname(absolute), { recursive: true });
      fs.writeFileSync(absolute, input, { mode: 0o755 });
    } else {
      fs.mkdirSync(absolute, { recursive: true });
      fs.writeFileSync(path.join(absolute, 'payload.bin'), input);
    }
  }
  const prepared = measureNativeSignerInputs(root, inputs);
  const receipt = {
    schemaVersion: 1,
    complete: true,
    version: '1.2.3',
    architecture: 'x86_64',
    gitCommit: '01'.repeat(20),
    signerInputsRootSha256: prepared.rootSha256
  };
  for (const input of inputs) {
    const target = fs.statSync(path.join(root, input)).isDirectory()
      ? path.join(root, input, 'payload.bin')
      : path.join(root, input);
    const original = fs.readFileSync(target);
    fs.appendFileSync(target, '-mutated');
    const current = measureNativeSignerInputs(root, inputs);
    assert.throws(() => validatePreparationForSigner({
      receipt,
      version: receipt.version,
      architecture: receipt.architecture,
      gitCommit: receipt.gitCommit,
      signerInputsRootSha256: current.rootSha256
    }), /do not match/, input);
    fs.writeFileSync(target, original);
  }
  fs.rmSync(root, { recursive: true, force: true });
});

test('signed package receipt is canonical and detects package or receipt substitution', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const receipt = createNativePackageSigningReceipt(receiptOptions());
  const { bytes, signature } = signNativePackageSigningReceipt(receipt, privateKey);
  assert.equal(bytes.toString('utf8'), canonicalJson(receipt));
  assert.deepEqual(verifyNativePackageSigningReceipt(bytes, signature, publicKey), receipt);

  const substituted = Buffer.from(bytes);
  substituted[substituted.indexOf(Buffer.from('OpenBurnBar.deb'))] ^= 1;
  assert.throws(
    () => verifyNativePackageSigningReceipt(substituted, signature, publicKey),
    /signature verification failed/
  );
  const wrongSignature = Buffer.from(signature);
  wrongSignature[0] ^= 1;
  assert.throws(
    () => verifyNativePackageSigningReceipt(bytes, wrongSignature, publicKey),
    /signature verification failed/
  );

  const substitutedIdentity = Buffer.from(bytes);
  substitutedIdentity[substitutedIdentity.indexOf(Buffer.from('linuxabcdef012345'))] ^= 1;
  assert.throws(
    () => verifyNativePackageSigningReceipt(substitutedIdentity, signature, publicKey),
    /signature verification failed/
  );
});

test('signed package receipt requires a valid non-placeholder Firebase web app identity', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  for (const firebaseAppId of [
    undefined,
    '',
    '1:123:linux:not-web',
    '1:0:web:linuxabcdef012345',
    '1:123:web:placeholder',
    `1:123:web:${'a'.repeat(161)}`
  ]) {
    assert.throws(
      () => createNativePackageSigningReceipt({ ...receiptOptions(), firebaseAppId }),
      /receipt fields are invalid/
    );
    const invalidReceipt = {
      schemaVersion: 1,
      ...receiptOptions(),
      firebaseAppId
    };
    const bytes = Buffer.from(canonicalJson(invalidReceipt), 'utf8');
    const signature = crypto.sign(null, bytes, privateKey);
    assert.throws(
      () => verifyNativePackageSigningReceipt(bytes, signature, publicKey),
      /receipt fields are invalid/
    );
  }
});

test('architecture closure identity is sourced from the verified signing receipt', () => {
  const releaseSource = fs.readFileSync(new URL('./build-linux-release.mjs', import.meta.url), 'utf8');
  assert.match(releaseSource, /firebaseAppId: signingReceipt\?\.firebaseAppId \?\? null/u);
  assert.doesNotMatch(releaseSource, /firebaseAppId:\s*process\.env/u);
});

test('final package validation rejects stale, substituted, or extra native artifacts', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-package-files-'));
  fs.mkdirSync(path.join(root, 'bundle'));
  const deb = path.join(root, 'bundle/OpenBurnBar.deb');
  const rpm = path.join(root, 'bundle/OpenBurnBar.rpm');
  fs.writeFileSync(deb, 'deb-payload');
  fs.writeFileSync(rpm, 'rpm-payload');
  const receipt = createNativePackageSigningReceipt({
    ...receiptOptions(),
    packages: [
      {
        type: 'deb',
        file: 'bundle/OpenBurnBar.deb',
        size: fs.statSync(deb).size,
        sha256: crypto.createHash('sha256').update(fs.readFileSync(deb)).digest('hex'),
        installedManifestDigestSha256: '05'.repeat(32)
      },
      {
        type: 'rpm',
        file: 'bundle/OpenBurnBar.rpm',
        size: fs.statSync(rpm).size,
        sha256: crypto.createHash('sha256').update(fs.readFileSync(rpm)).digest('hex'),
        installedManifestDigestSha256: '07'.repeat(32)
      }
    ]
  });
  const discovered = [{ type: 'deb', file: deb }, { type: 'rpm', file: rpm }];
  assert.doesNotThrow(() => validateSignedPackageArtifacts(root, receipt, discovered));
  fs.appendFileSync(deb, '-substituted');
  assert.throws(() => validateSignedPackageArtifacts(root, receipt, discovered), /changed or is missing: deb/);
  fs.writeFileSync(deb, 'deb-payload');
  assert.throws(
    () => validateSignedPackageArtifacts(root, receipt, [...discovered, { type: 'rpm', file: rpm }]),
    /do not exactly match/
  );
  fs.rmSync(root, { recursive: true, force: true });
});
