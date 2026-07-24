import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { installedPackageVerificationStep } from './lib/linux-package-smoke-installed.mjs';

const source = fs.readFileSync(new URL('./smoke-linux-packages.mjs', import.meta.url), 'utf8');

function branchBody(start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.notEqual(from, -1, `missing branch marker: ${start}`);
  assert.notEqual(to, -1, `missing branch terminator: ${end}`);
  return source.slice(from, to);
}

test('deb and rpm smoke verify exact live installed evidence after install and before uninstall', () => {
  for (const [label, body, install, uninstall] of [
    [
      'deb',
      branchBody("if (artifact.type === 'deb')", "} else if (artifact.type === 'rpm')"),
      'steps.push(dpkgInstall);',
      'const dpkgRemove ='
    ],
    [
      'rpm',
      branchBody("} else if (artifact.type === 'rpm')", "} else if (artifact.type === 'appimage')"),
      'steps.push(rpmInstall);',
      'const rpmErase ='
    ]
  ]) {
    const installIndex = body.indexOf(install);
    const verifyIndex = body.indexOf('installedPackageVerificationStep({ artifact, readSubject: readShardSubject })');
    const uninstallIndex = body.indexOf(uninstall);
    assert.ok(installIndex >= 0, `${label} install is missing`);
    assert.ok(verifyIndex > installIndex, `${label} live verification must follow installation`);
    assert.ok(uninstallIndex > verifyIndex, `${label} live verification must precede uninstall`);
  }
});

test('live package smoke binds copied shard manifest and signature bytes', () => {
  for (const marker of [
    "import { installedPackageVerificationStep } from './lib/linux-package-smoke-installed.mjs'",
    'installedPackageVerificationStep({ artifact, readSubject: readShardSubject })'
  ]) {
    assert.ok(source.includes(marker), `missing installed-evidence binding: ${marker}`);
  }
});

test('live package verification helper propagates exact manifest/signature bytes and failures', () => {
  const artifact = {
    type: 'deb',
    architecture: 'x86_64',
    installedManifest: { file: 'manifest' },
    installedManifestSignature: { file: 'signature' }
  };
  const manifestBytes = Buffer.from('{"packageVersion":"1.2.3"}\n');
  const signatureBytes = Buffer.alloc(64, 7);
  const readSubject = (record) => record.file === 'manifest' ? manifestBytes : signatureBytes;
  let observed = null;
  const passed = installedPackageVerificationStep({
    artifact,
    readSubject,
    verifier: (input) => {
      observed = input;
      return { verification: { passed: true } };
    }
  });
  assert.equal(passed.exitCode, 0);
  assert.equal(observed.expectedManifestBytes, manifestBytes);
  assert.equal(observed.expectedSignatureBytes, signatureBytes);
  assert.equal(observed.installedManifest.packageVersion, '1.2.3');

  const invalidJson = installedPackageVerificationStep({
    artifact,
    readSubject: (record) => record.file === 'manifest' ? Buffer.from('not-json') : signatureBytes,
    verifier: () => assert.fail('invalid JSON must not reach the verifier')
  });
  assert.equal(invalidJson.exitCode, 1);
  assert.match(invalidJson.stderr, /not valid JSON/u);

  const rejectedSignature = installedPackageVerificationStep({
    artifact,
    readSubject,
    verifier: () => { throw new Error('signature bytes do not match'); }
  });
  assert.equal(rejectedSignature.exitCode, 1);
  assert.match(rejectedSignature.stderr, /signature bytes do not match/u);
});
