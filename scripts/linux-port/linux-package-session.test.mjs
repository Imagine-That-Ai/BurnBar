import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import {
  aggregateArchitectureLifecycle,
  isArchitectureSessionBaselineBlocked,
  requiredLifecycleSteps,
  validateArchUpdateRollbackReport,
  validateArchitectureSessionSet
} from './lib/linux-package-session.mjs';

const releaseWorkflow = readFileSync(path.resolve('.github/workflows/linux-release.yml'), 'utf8');
const architectureFinalizer = readFileSync(path.resolve('scripts/linux-port/finalize-linux-architecture-session.mjs'), 'utf8');

const manifest = { supportedArchitectures: ['aarch64', 'x86_64'] };
const version = '1.2.3';
const commit = 'a'.repeat(40);
const archArtifact = {
  file: '.linux-shard/artifacts/openburnbar-1.2.3-1-aarch64.pkg.tar.zst',
  sha256: 'a'.repeat(64),
  size: 1234
};

test('missing previous Debian assets block lifecycle without aborting the shard', () => {
  const stage = releaseWorkflow.slice(
    releaseWorkflow.indexOf('Stage current and previous packages for installed lifecycle proof'),
    releaseWorkflow.indexOf('Verify Arch package update, rollback, and data preservation')
  );
  assert.match(stage, /if ! gh release download "linux-v\$\{PREVIOUS_VERSION\}"/u);
  assert.match(stage, /No previous Debian package matched/u);
  assert.match(stage, /dpkg lifecycle will remain blocked/u);
});

function archLifecycleReport() {
  const previous = {
    file: '.linux-shard/previous/arch/openburnbar-1.2.2-1-aarch64.pkg.tar.zst',
    sha256: 'c'.repeat(64),
    size: 1200,
    version: '1.2.2'
  };
  const candidate = { ...archArtifact, version };
  const steps = [
    { command: 'pacman -Syu --noconfirm --needed gtk3', exitCode: 0 },
    { command: 'pacman -T gtk3', exitCode: 0 }
  ];
  for (const record of [previous, candidate, previous, candidate]) {
    steps.push(
      { command: `pacman -U --noconfirm /workspace/${record.file}`, exitCode: 0 },
      { command: 'pacman -Qi openburnbar', exitCode: 0 },
      { command: '/usr/bin/openburnbar-linux-desktop --version', exitCode: 0 },
      { command: '/usr/libexec/openburnbar-daemon-launch --help', exitCode: 0 }
    );
  }
  const transition = (from, to) => ({
    status: 'passed', manager: 'pacman', packageName: 'openburnbar', architecture: 'aarch64',
    fromVersion: from.version, toVersion: to.version,
    fromSha256: from.sha256, toSha256: to.sha256
  });
  const sentinelSha256 = 'd'.repeat(64);
  const previousPrefix = '.linux-shard/previous/arch/';
  const provenance = (file, fill) => ({
    file: `${previousPrefix}${file}`,
    sha256: fill.repeat(64),
    size: 64
  });
  return {
    schemaVersion: 1,
    manager: 'pacman',
    packageName: 'openburnbar',
    architecture: 'aarch64',
    gitCommit: commit,
    candidate,
    previous,
    previousProvenance: {
      releaseTag: 'linux-v1.2.2',
      releaseCommit: 'b'.repeat(40),
      packageSignature: provenance('openburnbar-1.2.2-1-aarch64.pkg.tar.zst.ed25519.sig', 'e'),
      installedManifest: provenance('openburnbar-1.2.2-aarch64.installed-manifest.json', 'f'),
      installedManifestSignature: provenance('openburnbar-1.2.2-aarch64.installed-manifest.ed25519', '1'),
      productProofClosure: provenance('product-proof-closure.json', '2'),
      productProofClosureSignature: provenance('product-proof-closure.json.ed25519.sig', '3')
    },
    steps,
    lifecycle: {
      update: transition(previous, candidate),
      rollback: transition(candidate, previous),
      dataPreservation: {
        status: 'passed', sentinelSha256,
        afterPreviousSha256: sentinelSha256,
        afterUpdateSha256: sentinelSha256,
        afterRollbackSha256: sentinelSha256,
        afterRestoreSha256: sentinelSha256
      }
    },
    passed: true
  };
}
function session(architecture, status = 'passed') {
  return {
    schemaVersion: 1,
    architecture,
    version,
    gitCommit: commit,
    lifecycle: Object.fromEntries(requiredLifecycleSteps.map((step) => [step, { status }])),
    passed: status === 'passed'
  };
}

test('two green architecture sessions produce a green lifecycle', () => {
  const sessions = [session('aarch64'), session('x86_64')];
  assert.deepEqual(validateArchitectureSessionSet({ manifest, sessions, version, commit }), []);
  const aggregate = aggregateArchitectureLifecycle({ manifest, sessions });
  assert.equal(aggregate.passed, true);
  assert.equal(aggregate.failedCount, 0);
});

test('missing and blocked architecture sessions fail closed', () => {
  const blocked = session('aarch64');
  blocked.lifecycle.rollback = { status: 'blocked', reason: 'previous package missing' };
  blocked.passed = false;
  const sessions = [blocked];
  const failures = validateArchitectureSessionSet({ manifest, sessions, version, commit });
  assert.ok(failures.some((failure) => /rollback/.test(failure)));
  assert.ok(failures.some((failure) => /missing architecture session: x86_64/.test(failure)));
  const aggregate = aggregateArchitectureLifecycle({ manifest, sessions });
  assert.equal(aggregate.passed, false);
  assert.equal(aggregate.lifecycle.rollback.status, 'blocked');
});

test('known incompatible legacy Debian baseline is eligible only for prerelease blocking', () => {
  const reason = 'Previous same-architecture Linux .deb predates the daemon launcher contract; update, rollback, and data-preservation promotion gates remain blocked until a compatible baseline is available.';
  const sessions = [session('aarch64'), session('x86_64')];
  for (const candidate of sessions) {
    for (const step of ['update', 'rollback', 'dataPreservation']) {
      candidate.lifecycle[step] = { status: 'blocked', reason };
    }
    candidate.passed = false;
  }
  assert.equal(isArchitectureSessionBaselineBlocked({ manifest, sessions }), true);
});

test('Arch missing-baseline reports remain explicit in architecture-session finalization', () => {
  assert.match(architectureFinalizer, /No previous same-architecture Arch package was supplied/u);
  assert.match(architectureFinalizer, /\['update', 'rollback', 'dataPreservation'\]\.every/u);
  assert.match(architectureFinalizer, /archLifecycle = blockedLifecycle/u);
});

test('cross-commit, duplicate, and version drift are rejected', () => {
  const first = session('aarch64');
  const duplicate = session('aarch64');
  duplicate.version = '9.9.9';
  duplicate.gitCommit = 'b'.repeat(40);
  const failures = validateArchitectureSessionSet({
    manifest,
    sessions: [first, duplicate, session('x86_64')],
    version,
    commit
  });
  for (const pattern of [/duplicate/, /version does not match/, /commit does not match/, /missing or extra/]) {
    assert.ok(failures.some((failure) => pattern.test(failure)), pattern);
  }
});

test('Arch lifecycle proof binds pacman transitions to exact candidate and previous packages', async (t) => {
  const valid = archLifecycleReport();
  assert.deepEqual(validateArchUpdateRollbackReport({
    report: valid,
    architecture: 'aarch64',
    version,
    gitCommit: commit,
    artifact: archArtifact
  }), valid.lifecycle);
  for (const [name, mutate, pattern] of [
    ['Debian substitution', (report) => { report.manager = 'dpkg'; }, /passed pacman lifecycle/u],
    ['candidate hash drift', (report) => { report.candidate.sha256 = 'e'.repeat(64); }, /architecture closure/u],
    ['wrong architecture', (report) => { report.architecture = 'x86_64'; }, /architecture and commit/u],
    ['newer previous package', (report) => { report.previous.version = '2.0.0'; }, /distinct older release/u],
    ['transition hash drift', (report) => { report.lifecycle.rollback.toSha256 = 'f'.repeat(64); }, /not release-bound/u],
    ['data mutation', (report) => { report.lifecycle.dataPreservation.afterRollbackSha256 = 'f'.repeat(64); }, /data-preservation/u],
    ['failed command', (report) => { report.steps[0].exitCode = 1; }, /successful command sequence/u],
    ['command substitution', (report) => { report.steps[2].command = 'dpkg -i previous.deb'; }, /command sequence/u],
    ['package path suffix spoof', (report) => {
      report.steps[2].command = `pacman -U --noconfirm /tmp/wrong ${report.previous.file}`;
    }, /command sequence/u],
    ['internal traversal in previous package path', (report) => {
      report.previous.file = '.linux-shard/previous/arch/../../../../tmp/substituted.pkg.tar.zst';
      report.steps[2].command = `pacman -U --noconfirm /workspace/${report.previous.file}`;
      report.steps[10].command = `pacman -U --noconfirm /workspace/${report.previous.file}`;
    }, /invalid/u],
    ['dot segment in previous package path', (report) => {
      report.previous.file = '.linux-shard/previous/arch/./substituted.pkg.tar.zst';
      report.steps[2].command = `pacman -U --noconfirm /workspace/${report.previous.file}`;
      report.steps[10].command = `pacman -U --noconfirm /workspace/${report.previous.file}`;
    }, /invalid/u],
    ['previous package outside the authenticated staging directory', (report) => {
      report.previous.file = '.linux-shard/session/substituted.pkg.tar.zst';
      report.steps[2].command = `pacman -U --noconfirm /workspace/${report.previous.file}`;
      report.steps[10].command = `pacman -U --noconfirm /workspace/${report.previous.file}`;
    }, /confined/u],
    ['previous provenance release tag substitution', (report) => {
      report.previousProvenance.releaseTag = 'linux-v9.9.9';
    }, /release identity/u],
    ['previous provenance sidecar traversal', (report) => {
      report.previousProvenance.productProofClosure.file = '.linux-shard/previous/arch/../product-proof-closure.json';
    }, /invalid/u],
    ['previous provenance sidecar size substitution', (report) => {
      report.previousProvenance.packageSignature.size = 0;
    }, /invalid/u]
  ]) {
    await t.test(name, () => {
      const report = structuredClone(valid);
      mutate(report);
      assert.throws(() => validateArchUpdateRollbackReport({
        report,
        architecture: 'aarch64',
        version,
        gitCommit: commit,
        artifact: archArtifact
      }), pattern);
    });
  }
});

test('architecture finalizer fails closed when Arch lifecycle subjects are unauthenticated', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'openburnbar-linux-session-'));
  const sessionDir = path.join(root, 'session');
  const archLifecycleDir = path.join(root, 'arch-lifecycle');
  const smokeDir = path.join(root, 'smoke');
  mkdirSync(sessionDir, { recursive: true });
  mkdirSync(archLifecycleDir, { recursive: true });
  mkdirSync(smokeDir, { recursive: true });
  const json = (file, value) => writeFileSync(file, `${JSON.stringify(value)}\n`);

  try {
    json(path.join(root, 'architecture-closure.json'), {
      schemaVersion: 1,
      architecture: 'aarch64',
      version,
      git: { commit },
      artifacts: [{
        type: 'arch',
        ...archArtifact,
        installedManifest: { sha256: 'b'.repeat(64) }
      }]
    });
    json(path.join(smokeDir, 'architecture-smoke.json'), { passed: true });
    json(path.join(smokeDir, 'arch-package-smoke.json'), {
      passed: true,
      architecture: 'aarch64',
      version,
      gitCommit: commit,
      packageSha256: 'a'.repeat(64),
      installedManifestSha256: 'b'.repeat(64)
    });
    json(path.join(sessionDir, 'linux-desktop-session-report.json'), {
      profile: 'test',
      package: {
        uninstallVerified: true,
        executable: '/usr/bin/openburnbar-linux-desktop',
        shellVersionReadback: `OpenBurnBar ${version}`
      },
      accessibility: { keyboardFocus: { pass: true }, zoom: { pass: true } }
    });
    json(path.join(sessionDir, 'daemon-session-oracle.json'), {
      status: 'ready',
      daemonBinary: '/usr/bin/openburnbar-daemon',
      mode: 'openburnbar-daemon-af-unix'
    });
    json(path.join(sessionDir, 'daemon-health-readback.json'), {
      passed: true,
      response: { result: { daemonVersion: version } }
    });
    json(path.join(sessionDir, 'package-update-rollback.json'), {
      lifecycle: Object.fromEntries(
        ['update', 'rollback', 'dataPreservation'].map((step) => [step, { status: 'passed' }])
      )
    });
    json(path.join(archLifecycleDir, 'arch-package-update-rollback.json'), archLifecycleReport());

    const result = spawnSync(
      process.execPath,
      [path.resolve('scripts/linux-port/finalize-linux-architecture-session.mjs')],
      { encoding: 'utf8', env: { ...process.env, OPENBURNBAR_LINUX_RELEASE_OUT: root } }
    );
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(readFileSync(path.join(root, 'architecture-session.json'), 'utf8'));
    assert.equal(report.packageSmokePassed, true);
    assert.equal(report.passed, false);
    assert.match(report.blockers.join('\n'), /authenticated|release-bound|release-unbound/u);

    json(path.join(smokeDir, 'arch-package-smoke.json'), {
      passed: true,
      architecture: 'aarch64',
      version,
      gitCommit: commit,
      packageSha256: 'c'.repeat(64),
      installedManifestSha256: 'b'.repeat(64)
    });
    const drifted = spawnSync(
      process.execPath,
      [path.resolve('scripts/linux-port/finalize-linux-architecture-session.mjs')],
      { encoding: 'utf8', env: { ...process.env, OPENBURNBAR_LINUX_RELEASE_OUT: root } }
    );
    assert.equal(drifted.status, 0, drifted.stderr);
    const driftedReport = JSON.parse(readFileSync(path.join(root, 'architecture-session.json'), 'utf8'));
    assert.equal(driftedReport.passed, false);
    assert.match(driftedReport.blockers.join('\n'), /Arch pacman/u);

    json(path.join(smokeDir, 'arch-package-smoke.json'), {
      passed: true,
      architecture: 'aarch64',
      version,
      gitCommit: commit,
      packageSha256: archArtifact.sha256,
      installedManifestSha256: 'b'.repeat(64)
    });
    const substituted = archLifecycleReport();
    substituted.manager = 'dpkg';
    json(path.join(archLifecycleDir, 'arch-package-update-rollback.json'), substituted);
    const rejected = spawnSync(
      process.execPath,
      [path.resolve('scripts/linux-port/finalize-linux-architecture-session.mjs')],
      { encoding: 'utf8', env: { ...process.env, OPENBURNBAR_LINUX_RELEASE_OUT: root } }
    );
    assert.equal(rejected.status, 0, rejected.stderr);
    const rejectedReport = JSON.parse(readFileSync(path.join(root, 'architecture-session.json'), 'utf8'));
    assert.equal(rejectedReport.passed, false);
    assert.match(rejectedReport.blockers.join('\n'), /pacman update\/rollback/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
