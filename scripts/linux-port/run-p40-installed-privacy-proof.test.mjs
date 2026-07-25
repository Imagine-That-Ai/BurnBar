import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  P40_DEFAULT_RETENTION_RULES,
  P40_ENVIRONMENTS,
  P40_STORES
} from './lib/p40-privacy-proof.mjs';
import { SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';
import { buildSession } from './run-p40-privacy-rpc-session.mjs';

const script = fileURLToPath(new URL('./run-p40-installed-privacy-proof.sh', import.meta.url));
const root = path.resolve(path.dirname(script), '../..');
const source = fs.readFileSync(script, 'utf8');
const head = 'a'.repeat(40);
const runId = '29401347808';
const digest = `sha256:${'b'.repeat(64)}`;
const environment = 'ubuntu-24.04-gnome-x11-aarch64';

const expectedMappings = {
  'ubuntu-24.04-gnome-x11-x86_64': ['x86_64', 'deb', 'ubuntu', '24.04', 'GNOME', 'X11', 'open-burn-bar'],
  'ubuntu-24.04-gnome-x11-aarch64': ['aarch64', 'deb', 'ubuntu', '24.04', 'GNOME', 'X11', 'open-burn-bar'],
  'ubuntu-24.04-gnome-wayland-x86_64': ['x86_64', 'deb', 'ubuntu', '24.04', 'GNOME', 'Wayland', 'open-burn-bar'],
  'ubuntu-24.04-gnome-wayland-aarch64': ['aarch64', 'deb', 'ubuntu', '24.04', 'GNOME', 'Wayland', 'open-burn-bar'],
  'fedora-kde-wayland-x86_64': ['x86_64', 'rpm', 'fedora', '', 'KDE Plasma', 'Wayland', 'open-burn-bar'],
  'fedora-kde-wayland-aarch64': ['aarch64', 'rpm', 'fedora', '', 'KDE Plasma', 'Wayland', 'open-burn-bar'],
  'arch-sway-wayland-x86_64': ['x86_64', 'arch', 'arch', '', 'Sway/wlroots', 'Wayland', 'openburnbar']
};

function shell(command, { env = {}, cwd = root } = {}) {
  return spawnSync('/bin/bash', ['-c', command], {
    cwd,
    env: { ...process.env, ...env },
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: 8 * 1024 * 1024
  });
}

function quote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function makeTemp(name) {
  return fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), `openburnbar-p40-${name}-`));
}

function writeExecutable(file, body) {
  fs.writeFileSync(file, body, { mode: 0o700 });
  fs.chmodSync(file, 0o700);
}

function observations() {
  return {
    inventory: {
      evidencePaths: ['privacy/inventory.json'],
      metadataOnly: true,
      noAbsolutePaths: true,
      noContents: true,
      stores: P40_STORES.map((store) => ({ store, state: 'ready', bytes: 128 }))
    },
    deletion: {
      changedPreviewRejected: true,
      confirmationExact: true,
      evidencePaths: ['privacy/deletion.json'],
      expiredPreviewRejected: true,
      idempotent: true,
      noAbsolutePaths: true,
      noContentsReturned: true,
      outsidePathUntouched: true,
      previewScopeBound: true,
      selectedScope: true
    },
    export: {
      encrypted: true,
      evidencePaths: ['privacy/export.json'],
      formatVersion: 1,
      noPlaintextOnDisk: true,
      ownerOnlyPermissions: true,
      passphraseNotPersisted: true,
      selectedScope: true
    },
    retention: {
      agedExpansionPurged: true,
      appliedRules: P40_STORES.map((store) => ({
        store,
        maxAgeSeconds: 3_600,
        maxBytes: 65_536
      })),
      defaultRules: structuredClone(P40_DEFAULT_RETENTION_RULES),
      evidencePaths: ['privacy/retention.json'],
      freshRouteRetained: true,
      invalidBoundsRejected: true,
      invalidConfirmationRejected: true,
      malformedStoreFailClosed: true,
      noMutationOnFailure: true,
      oldRoutePurged: true,
      statusObserved: true
    }
  };
}

function writeEvidenceTree(directory) {
  fs.mkdirSync(path.join(directory, 'privacy'), { recursive: true, mode: 0o700 });
  fs.chmodSync(directory, 0o700);
  fs.chmodSync(path.join(directory, 'privacy'), 0o700);
  const session = buildSession(
    {
      environmentId: environment,
      targetHead: head,
      candidateRunId: runId,
      candidateArtifactDigest: digest,
      packageVersion: '1.2.3',
      manifestSha256: 'c'.repeat(64)
    },
    P40_ENVIRONMENTS[environment],
    '1.2.3',
    'c'.repeat(64),
    observations()
  );
  const files = new Map([
    ['p40-live-session.json', session],
    ['privacy/inventory.json', {
      metadataOnly: session.observations.inventory.metadataOnly,
      stores: session.observations.inventory.stores
    }],
    ['privacy/deletion.json', { checks: session.observations.deletion }],
    ['privacy/export.json', { checks: session.observations.export }],
    ['privacy/retention.json', { checks: session.observations.retention }]
  ]);
  for (const [relative, document] of files) {
    const file = path.join(directory, relative);
    fs.writeFileSync(file, `${JSON.stringify(document)}\n`, { mode: 0o600 });
    fs.chmodSync(file, 0o600);
  }
}

test('source keeps candidate, installed trust, evidence, and cleanup contracts fail closed', () => {
  assert.match(source, /^set -euo pipefail$/mu);
  assert.match(source, /^umask 077$/mu);
  assert.match(source, /verifyLiveInstalledProduct/u);
  assert.match(source, /openburnbar-linux-ed25519\.pub\.pem/u);
  assert.match(source, /timingSafeEqual\(installedKey, repositoryKey\)/u);
  assert.match(source, /validateP40LiveSession/u);
  assert.match(source, /run-p40-privacy-rpc-session\.mjs/u);
  assert.match(source, /\/usr\/libexec\/openburnbar-daemon-launch/u);
  assert.match(source, /\/proc\/\$daemon_pid\/exe/u);
  assert.match(source, /expected exactly one \$expected_format/u);
  assert.match(source, /assert_no_symlink_components/u);
  assert.match(source, /trap cleanup EXIT/u);
  assert.match(source, /rm -rf -- "\$temporary_root"/u);
  assert.doesNotMatch(source, /(?:TEST_MODE|FIXTURE_MODE|ALLOW_UNTRUSTED|SKIP_VALIDATION|fake_environment)/u);
  assert.doesNotMatch(source, /source\s+\/etc\/os-release/u);

  const copyStart = source.indexOf('copy_validated_evidence()');
  const copyEnd = source.indexOf('\ncleanup()', copyStart);
  const copyBody = source.slice(copyStart, copyEnd);
  assert.ok(copyBody.indexOf('validate_evidence_tree "$evidence_root"') < copyBody.indexOf('atomic_copy'));
  assert.match(copyBody, /validate_evidence_tree "\$staging"/u);
});

test('all and only the seven canonical support environments map to exact native identities', () => {
  assert.deepEqual(Object.keys(expectedMappings), [...SUPPORT_ENVIRONMENTS]);
  const actual = shell(`
    source ${quote(script)}
    while IFS= read -r environment; do
      configure_environment "$environment"
      printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \\
        "$environment_id" "$expected_architecture" "$expected_format" "$expected_os_id" \\
        "$expected_os_version" "$expected_desktop" "$expected_session" "$expected_package_name"
    done <<< ${quote(Object.keys(expectedMappings).join('\n'))}
  `);
  assert.equal(actual.status, 0, actual.stderr);
  const rows = actual.stdout.trim().split('\n').map((line) => line.split('\t'));
  assert.equal(rows.length, SUPPORT_ENVIRONMENTS.length);
  for (const [id, ...mapping] of rows) assert.deepEqual(mapping, expectedMappings[id]);

  const unknown = shell(`source ${quote(script)}; configure_environment not-a-real-environment`);
  assert.notEqual(unknown.status, 0);
  assert.match(unknown.stderr, /unknown canonical P-40 environment/u);
});

test('native package install and reinstall commands are selected without root', () => {
  const temporary = makeTemp('commands');
  const bin = path.join(temporary, 'bin');
  const log = path.join(temporary, 'commands.log');
  fs.mkdirSync(bin, { mode: 0o700 });
  writeExecutable(path.join(bin, 'sudo'), `#!/bin/sh\nprintf '%s\\n' "$*" >> "$P40_COMMAND_LOG"\n`);
  writeExecutable(path.join(bin, 'rpm'), `#!/bin/sh
if test "\${MOCK_RPM_STATUS:-1}" = 0; then
  printf '%s\\n' "\${MOCK_RPM_IDENTITY:-}"
  exit 0
fi
exit 1
`);
  const cases = [
    ['deb', '0', 'apt-get install -y --reinstall /candidate/open burnbar.deb'],
    ['rpm', '1', 'dnf install -y /candidate/open burnbar.rpm'],
    ['rpm', '0', 'dnf reinstall -y /candidate/open burnbar.rpm'],
    ['arch', '0', 'pacman -U --noconfirm /candidate/open burnbar.pkg.tar.zst']
  ];
  try {
    for (const [format, rpmStatus, expected] of cases) {
      fs.writeFileSync(log, '');
      const result = shell(`
        source ${quote(script)}
        expected_format=${quote(format)}
        expected_architecture=x86_64
        expected_package_name=${quote(format === 'arch' ? 'openburnbar' : 'open-burn-bar')}
        candidate_package=${quote(`/candidate/open burnbar.${format === 'arch' ? 'pkg.tar.zst' : format}`)}
        candidate_version=1.2.3
        install_candidate_package
      `, {
        env: {
          PATH: `${bin}:${process.env.PATH}`,
          P40_COMMAND_LOG: log,
          MOCK_RPM_STATUS: rpmStatus,
          MOCK_RPM_IDENTITY: '1.2.3\tx86_64'
        }
      });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(fs.readFileSync(log, 'utf8').trim(), expected);
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('candidate selection is exact, architecture-bound, and rejects symlink traversal', () => {
  const temporary = makeTemp('selection');
  const input = path.join(temporary, 'input');
  const bin = path.join(temporary, 'bin');
  fs.mkdirSync(input, { mode: 0o700 });
  fs.mkdirSync(bin, { mode: 0o700 });
  for (const name of ['candidate-amd64.deb', 'candidate-arm64.deb', 'other-amd64.deb']) {
    fs.writeFileSync(path.join(input, name), name);
  }
  writeExecutable(path.join(bin, 'dpkg-deb'), `#!/bin/sh
file="$2"
field="$3"
case "$(basename "$file"):$field" in
  candidate-amd64.deb:Package) printf 'open-burn-bar\\n' ;;
  candidate-amd64.deb:Version) printf '1.2.3\\n' ;;
  candidate-amd64.deb:Architecture) printf 'amd64\\n' ;;
  candidate-arm64.deb:Package) printf 'open-burn-bar\\n' ;;
  candidate-arm64.deb:Version) printf '1.2.3\\n' ;;
  candidate-arm64.deb:Architecture) printf 'arm64\\n' ;;
  other-amd64.deb:Package) printf 'not-openburnbar\\n' ;;
  other-amd64.deb:Version) printf '9.9.9\\n' ;;
  other-amd64.deb:Architecture) printf 'amd64\\n' ;;
  duplicate-amd64.deb:Package) printf 'open-burn-bar\\n' ;;
  duplicate-amd64.deb:Version) printf '1.2.3\\n' ;;
  duplicate-amd64.deb:Architecture) printf 'amd64\\n' ;;
  *) exit 2 ;;
esac
`);
  try {
    const selected = shell(`
      source ${quote(script)}
      configure_environment ubuntu-24.04-gnome-x11-x86_64
      select_candidate_package ${quote(input)}
      printf '%s\\t%s\\n' "$candidate_package" "$candidate_version"
    `, { env: { PATH: `${bin}:${process.env.PATH}` } });
    assert.equal(selected.status, 0, selected.stderr);
    assert.equal(selected.stdout.trim(), `${path.join(input, 'candidate-amd64.deb')}\t1.2.3`);

    fs.writeFileSync(path.join(input, 'duplicate-amd64.deb'), 'duplicate');
    const duplicate = shell(`
      source ${quote(script)}
      configure_environment ubuntu-24.04-gnome-x11-x86_64
      select_candidate_package ${quote(input)}
    `, { env: { PATH: `${bin}:${process.env.PATH}` } });
    assert.notEqual(duplicate.status, 0);
    assert.match(duplicate.stderr, /expected exactly one deb open-burn-bar package for x86_64; found 2/u);

    const real = path.join(temporary, 'real');
    const linked = path.join(temporary, 'linked');
    fs.mkdirSync(real, { mode: 0o700 });
    fs.writeFileSync(path.join(real, 'package.deb'), 'package');
    fs.symlinkSync(real, linked);
    const symlink = shell(`
      source ${quote(script)}
      assert_regular_file_inside ${quote(real)} ${quote(path.join(linked, 'package.deb'))} candidate
    `);
    assert.notEqual(symlink.status, 0);
    assert.match(symlink.stderr, /traverses a symlink/u);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('validated evidence copy excludes extra files and rejects symlinked evidence', () => {
  const temporary = makeTemp('evidence');
  const evidence = path.join(temporary, 'source');
  const destination = path.join(temporary, 'destination');
  const working = path.join(temporary, 'openburnbar-p40-runner.test');
  const bin = path.join(temporary, 'bin');
  fs.mkdirSync(evidence, { recursive: true, mode: 0o700 });
  fs.mkdirSync(destination, { mode: 0o700 });
  fs.mkdirSync(working, { mode: 0o700 });
  fs.mkdirSync(bin, { mode: 0o700 });
  writeEvidenceTree(evidence);
  fs.writeFileSync(path.join(evidence, 'privacy', 'unvalidated.json'), '{}\n', { mode: 0o600 });
  writeExecutable(path.join(bin, 'stat'), `#!/usr/bin/env node
const fs = require('node:fs');
const [flag, format, file] = process.argv.slice(2);
if (flag !== '-c') process.exit(2);
const stat = fs.lstatSync(file);
if (format === '%u') process.stdout.write(String(stat.uid) + '\\n');
else if (format === '%a') process.stdout.write((stat.mode & 0o7777).toString(8) + '\\n');
else process.exit(2);
`);
  try {
    const copied = shell(`
      source ${quote(script)}
      environment_id=${quote(environment)}
      TARGET_HEAD=${quote(head)}
      CANDIDATE_RUN_ID=${quote(runId)}
      CANDIDATE_ARTIFACT_DIGEST=${quote(digest)}
      evidence_root=${quote(evidence)}
      runner_temp=${quote(temporary)}
      temporary_root=${quote(working)}
      copy_validated_evidence ${quote(destination)}
    `, { env: { PATH: `${bin}:${process.env.PATH}` } });
    assert.equal(copied.status, 0, copied.stderr);
    assert.equal(fs.existsSync(path.join(destination, 'privacy', 'unvalidated.json')), false);
    for (const relative of [
      'p40-live-session.json',
      'privacy/inventory.json',
      'privacy/deletion.json',
      'privacy/export.json',
      'privacy/retention.json'
    ]) {
      assert.equal(fs.statSync(path.join(destination, relative)).isFile(), true);
    }

    const inventory = path.join(evidence, 'privacy', 'inventory.json');
    const actualInventory = path.join(evidence, 'privacy', 'inventory-real.json');
    fs.renameSync(inventory, actualInventory);
    fs.symlinkSync(actualInventory, inventory);
    const rejected = shell(`
      source ${quote(script)}
      environment_id=${quote(environment)}
      TARGET_HEAD=${quote(head)}
      CANDIDATE_RUN_ID=${quote(runId)}
      CANDIDATE_ARTIFACT_DIGEST=${quote(digest)}
      validate_evidence_tree ${quote(evidence)}
    `);
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /traverses a symlink/u);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('EXIT cleanup kills the isolated daemon and removes only its validated temporary root', () => {
  const temporary = makeTemp('cleanup');
  const temporaryRoot = path.join(temporary, 'openburnbar-p40-runner.test');
  const pidFile = path.join(temporary, 'daemon.pid');
  fs.mkdirSync(temporaryRoot, { mode: 0o700 });
  const result = shell(`
    source ${quote(script)}
    runner_temp=${quote(temporary)}
    temporary_root=${quote(temporaryRoot)}
    sleep 300 &
    daemon_pid=$!
    printf '%s\\n' "$daemon_pid" > ${quote(pidFile)}
    trap cleanup EXIT
    exit 17
  `);
  const pid = Number.parseInt(fs.readFileSync(pidFile, 'utf8'), 10);
  assert.equal(result.status, 17, result.stderr);
  assert.equal(fs.existsSync(temporaryRoot), false);
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  assert.equal(fs.existsSync(temporary), true);
  fs.rmSync(temporary, { recursive: true, force: true });
});
