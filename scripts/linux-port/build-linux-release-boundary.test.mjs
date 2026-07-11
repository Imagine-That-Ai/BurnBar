import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const scriptPath = path.join(repoRoot, 'scripts/linux-port/build-linux-release.mjs');
const source = fs.readFileSync(scriptPath, 'utf8');
const coreManifest = fs.readFileSync(path.join(repoRoot, 'OpenBurnBarCore/Package.swift'), 'utf8');
const signingKeyName = 'OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM';

function invoke(args, extraEnvironment = {}) {
  const environment = { ...process.env, ...extraEnvironment };
  delete environment[signingKeyName];
  if (Object.hasOwn(extraEnvironment, signingKeyName)) {
    environment[signingKeyName] = extraEnvironment[signingKeyName];
  }
  environment.OPENBURNBAR_LINUX_RELEASE_OUT = fs.mkdtempSync(
    path.join(os.tmpdir(), 'openburnbar-release-boundary-')
  );
  const result = spawnSync(process.execPath, [scriptPath, '--architecture-shard', '--version', '1.2.3', ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: environment
  });
  fs.rmSync(environment.OPENBURNBAR_LINUX_RELEASE_OUT, { recursive: true, force: true });
  return result;
}

test('one-pass and ambiguous release modes fail before any build work', () => {
  for (const args of [[], ['--prepare-only', '--finalize-only']]) {
    const result = invoke(args);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /exactly one of --prepare-only or --finalize-only is required/u);
    assert.doesNotMatch(result.stdout, /daemon-build|package-build/u);
  }
});

test('prepare and finalize reject a signing key in their environment', () => {
  for (const mode of ['--prepare-only', '--finalize-only']) {
    const result = invoke([mode], { [signingKeyName]: 'must-not-reach-build-tools' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /is forbidden in build\/finalize phases/u);
    assert.doesNotMatch(result.stdout + result.stderr, /must-not-reach-build-tools/u);
  }
});

test('build orchestration cannot invoke native signing or inherit the ambient environment', () => {
  assert.doesNotMatch(source, /build-native-linux-packages\.mjs/u);
  assert.doesNotMatch(source, /env:\s*process\.env/u);
  assert.match(source, /runStep\('swift',[\s\S]*?\{ env: packageBuildEnv \}\)\);/u);
  assert.ok(source.includes("['npm', ['ci', '--no-audit', '--no-fund'], { cwd: appDir, env: packageBuildEnv }]"));
  assert.ok(source.includes("['npm', ['run', 'build'], { cwd: appDir, env: packageBuildEnv }]"));
  assert.match(source, /OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM: _excludedSigningKey/u);
  const irohBuild = source.indexOf("'--manifest-path',\n    irohManifest");
  const swiftBuild = source.indexOf("runStep('swift'");
  assert.ok(irohBuild >= 0 && swiftBuild > irohBuild);
  assert.match(source, /OPENBURNBAR_LINUX_IROH_LIBRARY_DIR: irohNativeLibraryDirectory/u);
  assert.match(source, /OPENBURNBAR_LINUX_IROH_BUILD_JOBS\?\.trim\(\) \|\| '1'/u);
});

test('standalone daemon statically links the iroh runtime archive', () => {
  assert.match(coreManifest, /libopenburnbar_iroh\.a/u);
  assert.match(coreManifest, /\.unsafeFlags\(\[libraryDirectory \+ "\/libopenburnbar_iroh\.a"\]\)/u);
  assert.doesNotMatch(coreManifest, /\.linkedLibrary\("openburnbar_iroh"\)/u);
});

test('finalization is bound to the successful preparation receipt', () => {
  for (const marker of [
    'architecture-preparation.json',
    'src-tauri/target/openburnbar-release/architecture-preparation.json',
    'publishedPreparationReceiptPath',
    'complete: blockers.length === 0',
    'gitCommit: git.commit',
    'daemonSha256',
    'irohNativeSha256',
    'attestdSha256',
    'appImageSha256',
    'signerInputsRootSha256',
    'signerInputRecordCount',
    'native-package-signing.json',
    'verifyNativePackageSigningReceipt',
    'validateSignedPackageArtifacts',
    'missing-preparation-receipt',
    'preparation-receipt-mismatch',
    'prepared-appimage-mismatch'
  ]) {
    assert.ok(source.includes(marker), marker);
  }
});

test('release runbook documents executable prepare, stdin signer, finalize order', () => {
  const runbook = fs.readFileSync(path.join(repoRoot, 'docs/linux-port/release-runbook.md'), 'utf8');
  const prepare = runbook.indexOf('--architecture-shard --prepare-only');
  const signer = runbook.indexOf('--private-key-stdin');
  const finalize = runbook.indexOf('--architecture-shard --finalize-only');
  assert.ok(prepare >= 0 && signer > prepare && finalize > signer);
  assert.match(runbook, /unset OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM/u);
  assert.match(runbook, /OPENBURNBAR_LINUX_INSTALLED_MANIFEST_KEY_FILE/u);
  assert.match(runbook, /architecture-preparation\.json/u);
});
