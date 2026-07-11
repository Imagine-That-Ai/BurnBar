import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import os from 'node:os';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const packagingRoot = path.join(repoRoot, 'packaging/linux');

function read(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function executable(relativePath) {
  return (fs.statSync(path.join(repoRoot, relativePath)).mode & 0o111) !== 0;
}

test('systemd broker contract is socket activated, local-only, and preserves peer inspection', () => {
  const service = read('packaging/linux/openburnbar-attestd.service');
  const socket = read('packaging/linux/openburnbar-attestd.socket');
  const unfolded = service.replace(/\\\n\s*/gu, '');

  assert.match(unfolded, /ExecStart=\/usr\/libexec\/openburnbar-attestd --socket-fd 3 --state-dir \/var\/lib\/openburnbar-attestd --manifest \/usr\/share\/openburnbar\/attestation\/installed-manifest\.json --manifest-signature \/usr\/share\/openburnbar\/attestation\/installed-manifest\.json\.sig --public-key \/usr\/share\/openburnbar\/attestation\/release-ed25519\.pub\.pem/u);
  assert.match(service, /^RestrictAddressFamilies=AF_UNIX$/mu);
  assert.match(service, /^IPAddressDeny=any$/mu);
  assert.match(service, /^CapabilityBoundingSet=.*\bCAP_SYS_PTRACE\b/mu);
  assert.doesNotMatch(service, /^CapabilityBoundingSet=.*\bCAP_SYS_ADMIN\b/mu);
  assert.doesNotMatch(service, /^(?:ProtectProc|ProcSubset|PrivatePIDs)=/mu);
  assert.match(socket, /^ListenSequentialPacket=\/run\/openburnbar\/attestd\.sock$/mu);
  assert.match(socket, /^PassCredentials=yes$/mu);
  assert.match(socket, /^SocketMode=0666$/mu);
  assert.match(socket, /^Service=openburnbar-attestd\.service$/mu);
});

test('installed manifest schema is strict and binds the only authorized client', () => {
  const schema = JSON.parse(read('packaging/linux/attestation/openburnbar-installed-manifest.schema.json'));
  const required = new Set(schema.required);
  for (const key of [
    'schemaVersion', 'product', 'appId', 'firebaseAppId', 'packageVersion', 'gitCommit',
    'packageArchitecture', 'packageFormat', 'packageName', 'policyId',
    'brokerProtocolVersion', 'installedFilesRootSha256', 'authorizedClients', 'files'
  ]) {
    assert.ok(required.has(key), `schema requires ${key}`);
  }
  assert.equal(schema.additionalProperties, false);
  assert.equal(schema.$defs.authorizedClient.additionalProperties, false);
  assert.equal(schema.$defs.authorizedClient.properties.path.const, '/usr/bin/openburnbar-daemon');
  assert.equal(schema.$defs.authorizedClient.properties.mode.const, 493);
  assert.equal(schema.$defs.regularFile.additionalProperties, false);
  assert.equal(schema.$defs.symlink.additionalProperties, false);
  assert.equal(schema.properties.brokerProtocolVersion.const, 2);
});

test('release metadata and Tauri keep privileged attestation in native packages only', () => {
  const release = JSON.parse(read('packaging/linux/release-manifest.json'));
  const tauri = JSON.parse(read('apps/linux-desktop/src-tauri/tauri.conf.json'));

  assert.deepEqual(release.rootAttestationBroker.productionPackages, ['deb', 'rpm']);
  assert.equal(
    release.rootAttestationBroker.defaultActivation,
    'disabled-until-enrolled-and-rollout-enabled'
  );
  assert.ok(release.rootAttestationBroker.peerAuthorization.some((entry) =>
    entry.includes('SCM_CREDENTIALS') && entry.includes('SOCK_SEQPACKET')));
  assert.equal(release.rootAttestationBroker.unsupportedPackages.appimage.length > 0, true);
  assert.equal(release.rootAttestationBroker.unsupportedPackages.flatpak.length > 0, true);
  assert.equal(release.rootAttestationBroker.unsupportedPackages.aur.length > 0, true);
  assert.deepEqual(tauri.bundle.targets, ['appimage']);
  assert.equal(tauri.bundle.linux.deb, undefined);
  assert.equal(tauri.bundle.linux.rpm, undefined);
});

test('package lifecycle hooks are executable and parse as POSIX shell', () => {
  const scripts = [
    'packaging/linux/debian/openburnbar-attestd.postinst',
    'packaging/linux/debian/openburnbar-attestd.prerm',
    'packaging/linux/debian/openburnbar-attestd.postrm',
    'packaging/linux/rpm/openburnbar-attestd.post',
    'packaging/linux/rpm/openburnbar-attestd.preun',
    'packaging/linux/rpm/openburnbar-attestd.postun',
    'packaging/linux/openburnbar-attestd-purge-state',
    'packaging/linux/openburnbar-attestd-activation-ready',
    'packaging/linux/openburnbar-restart-active-user-daemons'
  ];
  for (const script of scripts) {
    assert.equal(executable(script), true, `${script} is executable`);
    const result = spawnSync('sh', ['-n', path.join(repoRoot, script)], { encoding: 'utf8' });
    assert.equal(result.status, 0, `${script}: ${result.stderr}`);
  }
});

test('attestation activation requires both private enrollment and an explicit root marker', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-activation-'));
  const bin = path.join(root, 'bin');
  const state = path.join(root, 'tpm-enrollment.json');
  const akContext = path.join(root, 'ak.ctx');
  const marker = path.join(root, 'attestation-rollout-enabled');
  const helper = path.join(packagingRoot, 'openburnbar-attestd-activation-ready');
  fs.mkdirSync(bin);
  fs.writeFileSync(state, '{"key":"sealed"}\n', { mode: 0o600 });
  fs.writeFileSync(akContext, 'ak-context\n', { mode: 0o600 });
  fs.writeFileSync(marker, 'enabled\n', { mode: 0o644 });
  const stat = path.join(bin, 'stat');
  fs.writeFileSync(stat, `#!/bin/sh
case "$*" in
  *tpm-enrollment.json) printf '%s\\n' '0 600' ;;
  *ak.ctx) printf '%s\\n' '0 600' ;;
  *attestation-rollout-enabled) printf '%s\\n' '0 644' ;;
  *) exit 1 ;;
esac
`, { mode: 0o755 });

  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}` };
  assert.equal(spawnSync(helper, [state, akContext, marker], { env }).status, 0);
  fs.writeFileSync(marker, 'disabled\n', { mode: 0o644 });
  assert.equal(spawnSync(helper, [state, akContext, marker], { env }).status, 1);
  fs.writeFileSync(marker, 'enabled\n', { mode: 0o644 });
  fs.rmSync(akContext);
  assert.equal(spawnSync(helper, [state, akContext, marker], { env }).status, 1);
  fs.writeFileSync(akContext, 'ak-context\n', { mode: 0o600 });
  fs.rmSync(state);
  assert.equal(spawnSync(helper, [state, akContext, marker], { env }).status, 1);
  fs.rmSync(root, { recursive: true, force: true });
});

test('deb and rpm hooks keep the broker socket disabled until activation gates pass', () => {
  for (const file of [
    'packaging/linux/debian/openburnbar-attestd.postinst',
    'packaging/linux/rpm/openburnbar-attestd.post'
  ]) {
    const hook = read(file);
    const gate = hook.indexOf('"$ACTIVATION_READY"');
    const enable = hook.indexOf('enable "$SOCKET_UNIT"') >= 0
      ? hook.indexOf('enable "$SOCKET_UNIT"')
      : hook.indexOf('enable openburnbar-attestd.socket');
    assert.ok(gate >= 0 && enable > gate, `${file} gates enablement`);
    assert.match(hook, /disable .*openburnbar-attestd\.socket|disable "\$SOCKET_UNIT"/u);
    assert.match(hook, /stop .*openburnbar-attestd\.service|stop "\$SERVICE_UNIT"/u);
  }
});

test('fresh package transactions execute only the disable-and-stop broker branch', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-fresh-hooks-'));
  const bin = path.join(root, 'bin');
  const live = path.join(root, 'systemd-live');
  const state = path.join(root, 'state');
  const log = path.join(root, 'commands.log');
  const notReady = path.join(root, 'not-ready');
  fs.mkdirSync(bin);
  fs.mkdirSync(live);
  fs.writeFileSync(notReady, '#!/bin/sh\nexit 1\n', { mode: 0o755 });
  for (const command of ['systemctl', 'deb-systemd-helper']) {
    fs.writeFileSync(path.join(bin, command), `#!/bin/sh
printf '%s %s\\n' '${command}' "$*" >> "$OPENBURNBAR_TEST_LOG"
`, { mode: 0o755 });
  }
  fs.writeFileSync(path.join(bin, 'install'), `#!/bin/sh
for argument do destination=$argument; done
mkdir -p "$destination"
`, { mode: 0o755 });

  const cases = [
    ['packaging/linux/debian/openburnbar-attestd.postinst', ['configure']],
    ['packaging/linux/rpm/openburnbar-attestd.post', ['1']]
  ];
  for (const [sourcePath, args] of cases) {
    fs.writeFileSync(log, '');
    const staged = path.join(root, path.basename(sourcePath));
    const source = read(sourcePath)
      .replace('/usr/libexec/openburnbar-attestd-activation-ready', notReady)
      .replaceAll('/var/lib/openburnbar-attestd', state)
      .replaceAll('/run/systemd/system', live);
    fs.writeFileSync(staged, source, { mode: 0o755 });
    const result = spawnSync(staged, args, {
      encoding: 'utf8',
      env: {
        ...process.env,
        OPENBURNBAR_TEST_LOG: log,
        PATH: `${bin}:${process.env.PATH}`
      }
    });
    assert.equal(result.status, 0, `${sourcePath}: ${result.stderr}`);
    const commands = fs.readFileSync(log, 'utf8');
    assert.match(commands, /disable openburnbar-attestd\.socket/u);
    assert.match(commands, /stop openburnbar-attestd\.service openburnbar-attestd\.socket/u);
    assert.doesNotMatch(commands, /(?:^|\n)(?:systemctl|deb-systemd-helper) (?:--system )?enable /u);
    assert.doesNotMatch(commands, /restart openburnbar-attestd\.socket/u);
  }
  fs.rmSync(root, { recursive: true, force: true });
});

test('upgrade recovery reloads and try-restarts only active user daemon instances', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-user-recovery-'));
  const bin = path.join(root, 'bin');
  const runtime = path.join(root, 'run-user');
  const log = path.join(root, 'runuser.log');
  fs.mkdirSync(bin);
  for (const uid of ['1000', '1001']) fs.mkdirSync(path.join(runtime, uid), { recursive: true });
  fs.writeFileSync(path.join(bin, 'loginctl'), `#!/bin/sh
printf '%s\\n' '1000 alice' '1001 bob'
`, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'runuser'), `#!/bin/sh
printf '%s\\n' "$*" >> "$OPENBURNBAR_TEST_LOG"
user=$2
case "$*" in
  *'is-active --quiet openburnbar-daemon.service') [ "$user" = alice ] ;;
  *'daemon-reload') [ "$user" = alice ] ;;
  *'try-restart openburnbar-daemon.service') [ "$user" = alice ] ;;
  *) exit 97 ;;
esac
`, { mode: 0o755 });

  const helper = path.join(packagingRoot, 'openburnbar-restart-active-user-daemons');
  const result = spawnSync(helper, ['--runtime-root', runtime], {
    encoding: 'utf8',
    env: {
      ...process.env,
      OPENBURNBAR_TEST_LOG: log,
      PATH: `${bin}:${process.env.PATH}`
    }
  });
  assert.equal(result.status, 0, result.stderr);
  const calls = fs.readFileSync(log, 'utf8').trim().split('\n');
  assert.equal(calls.filter((line) => line.includes('alice') && line.includes('is-active')).length, 1);
  assert.equal(calls.filter((line) => line.includes('alice') && line.includes('daemon-reload')).length, 1);
  assert.equal(calls.filter((line) => line.includes('alice') && line.includes('try-restart')).length, 1);
  assert.equal(calls.filter((line) => line.includes('bob')).length, 1);
  assert.equal(calls.some((line) => /(?:^| )start(?: |$)/u.test(line)), false);
  fs.rmSync(root, { recursive: true, force: true });
});

test('user-daemon recovery reports reload failure and never restarts stale state', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-user-recovery-fail-'));
  const bin = path.join(root, 'bin');
  const runtime = path.join(root, 'run-user');
  const log = path.join(root, 'runuser.log');
  fs.mkdirSync(bin);
  fs.mkdirSync(path.join(runtime, '1000'), { recursive: true });
  fs.writeFileSync(path.join(bin, 'loginctl'), '#!/bin/sh\nprintf "%s\\n" "1000 alice"\n', { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'runuser'), `#!/bin/sh
printf '%s\\n' "$*" >> "$OPENBURNBAR_TEST_LOG"
case "$*" in
  *'is-active --quiet openburnbar-daemon.service') exit 0 ;;
  *'daemon-reload') exit 1 ;;
  *'try-restart'*) exit 98 ;;
  *) exit 97 ;;
esac
`, { mode: 0o755 });

  const helper = path.join(packagingRoot, 'openburnbar-restart-active-user-daemons');
  const result = spawnSync(helper, ['--runtime-root', runtime], {
    encoding: 'utf8',
    env: {
      ...process.env,
      OPENBURNBAR_TEST_LOG: log,
      PATH: `${bin}:${process.env.PATH}`
    }
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /daemon-reload failed for active user manager uid 1000/u);
  assert.doesNotMatch(fs.readFileSync(log, 'utf8'), /try-restart/u);
  fs.rmSync(root, { recursive: true, force: true });
});

test('deb and rpm post hooks invoke user-daemon recovery only for upgrade transactions', () => {
  const deb = read('packaging/linux/debian/openburnbar-attestd.postinst');
  const rpm = read('packaging/linux/rpm/openburnbar-attestd.post');
  assert.match(deb, /if \[ -n "\$\{2:-\}" \]; then/u);
  assert.match(rpm, /if \[ "\$\{1:-1\}" -gt 1 \]; then/u);
  assert.match(deb, /"\$RECOVER_USER_DAEMONS"/u);
  assert.match(rpm, /"\$RECOVER_USER_DAEMONS"/u);
  assert.match(deb, /user-daemon recovery helper is missing/u);
  assert.match(rpm, /user-daemon recovery helper is missing/u);
});

test('manual RPM state purge requires explicit identity-destruction confirmation', () => {
  const helper = read('packaging/linux/openburnbar-attestd-purge-state');
  assert.match(helper, /--confirm-device-identity-destruction/u);
  assert.match(helper, /exit 64/u);
  assert.match(helper, /attestation-rollout-enabled/u);
  assert.match(read('packaging/linux/openburnbar-attestd-activation-ready'), /ak\.ctx/u);
});

test('systemd units pass systemd-analyze when it is installed', (context) => {
  const available = spawnSync('systemd-analyze', ['--version'], { encoding: 'utf8' });
  if (available.error?.code === 'ENOENT') {
    context.skip('systemd-analyze is not installed on this host');
    return;
  }
  assert.equal(available.status, 0, available.stderr);
  const result = spawnSync('systemd-analyze', [
    'verify',
    path.join(packagingRoot, 'openburnbar-attestd.socket'),
    path.join(packagingRoot, 'openburnbar-attestd.service')
  ], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});
