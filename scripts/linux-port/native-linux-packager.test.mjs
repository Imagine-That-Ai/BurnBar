import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  INSTALLED_RELEASE_MANIFEST_NAME,
  __testing__,
  buildDebPackage,
  buildRpmPackage,
  canonicalJSON,
  createInstalledReleaseManifest,
  rpmOwnedPaths,
  stageNativeLinuxPackageRoot
} from './lib/native-linux-packager.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-package-'));
  const files = {};
  for (const name of [
    'gui', 'daemon', 'attestd', 'daemon-launch', 'daemon.service', 'attestd.service',
    'attestd.socket', 'desktop', 'safe-desktop', 'autostart', 'daemon-env', 'xdg',
    'schema', 'icon', 'purge-helper', 'activation-ready', 'restart-user-daemons'
  ]) {
    files[name] = path.join(root, name);
    fs.writeFileSync(files[name], `${name}\n`);
  }
  const swift = path.join(root, 'swift');
  const native = path.join(root, 'native');
  fs.mkdirSync(swift);
  fs.mkdirSync(native);
  fs.writeFileSync(path.join(swift, 'libswiftCore.so'), 'swift');
  fs.writeFileSync(path.join(native, 'libsqlcipher.so.0'), 'sqlcipher');
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  files['public-key'] = path.join(root, 'public-key.pem');
  fs.writeFileSync(files['public-key'], publicKey.export({ type: 'spki', format: 'pem' }));
  return { root, files, swift, native, privateKeyPem };
}

function stageOptions(f, packageType = 'deb') {
  return {
    root: path.join(f.root, `root-${packageType}`),
    guiBinary: f.files.gui,
    daemonBinary: f.files.daemon,
    attestdBinary: f.files.attestd,
    swiftRuntimeDir: f.swift,
    nativeRuntimeDir: f.native,
    version: '1.2.3',
    gitCommit: 'a'.repeat(40),
    architecture: 'x86_64',
    packageType,
    privateKeyPem: f.privateKeyPem,
    assets: {
      daemonLaunch: f.files['daemon-launch'],
      daemonUserService: f.files['daemon.service'],
      attestdService: f.files['attestd.service'],
      attestdSocket: f.files['attestd.socket'],
      attestdPurgeHelper: f.files['purge-helper'],
      attestdActivationReady: f.files['activation-ready'],
      restartActiveUserDaemons: f.files['restart-user-daemons'],
      desktopEntry: f.files.desktop,
      safeModeDesktopEntry: f.files['safe-desktop'],
      autostartEntry: f.files.autostart,
      daemonEnvExample: f.files['daemon-env'],
      customXdgDropInExample: f.files.xdg,
      attestationSchema: f.files.schema,
      attestationPublicKey: f.files['public-key'],
      icon: f.files.icon
    }
  };
}

test('canonical JSON recursively sorts object keys without reordering arrays', () => {
  assert.equal(canonicalJSON({ z: 1, a: { y: 2, b: 3 }, list: [{ z: 4, a: 5 }] }),
    '{"a":{"b":3,"y":2},"list":[{"a":5,"z":4}],"z":1}\n');
});

test('installed-files root matches the Rust broker golden vector', () => {
  const files = [
    {
      path: '/usr/share/openburnbar/\u00e9.txt',
      type: 'file',
      sha256: '05'.repeat(32),
      size: 5,
      mode: '0644',
      uid: 0,
      gid: 0
    },
    {
      path: '/usr/lib/openburnbar/current',
      type: 'symlink',
      target: '../v1',
      mode: '0777',
      uid: 0,
      gid: 0
    },
    {
      path: '/usr/share/applications/dev.openburnbar.OpenBurnBar.SafeMode.desktop',
      type: 'file',
      sha256: '04'.repeat(32),
      size: 4,
      mode: '0644',
      uid: 0,
      gid: 0
    },
    {
      path: '/usr/bin/openburnbar-daemon',
      type: 'file',
      sha256: '01'.repeat(32),
      size: 3,
      mode: '0755',
      uid: 0,
      gid: 0
    },
    {
      path: '/usr/lib/openburnbar/_Swift.so',
      type: 'file',
      sha256: '03'.repeat(32),
      size: 3,
      mode: '0644',
      uid: 0,
      gid: 0
    },
    {
      path: '/usr/share/applications/dev.openburnbar.OpenBurnBar.desktop',
      type: 'file',
      sha256: '02'.repeat(32),
      size: 2,
      mode: '0644',
      uid: 0,
      gid: 0
    }
  ];
  assert.equal(
    __testing__.filesRoot(files),
    'b86bd33740f7c26f3b4f959afcb9a5cb055f3c3b127ad6ee9f3f627c1c30f9e4'
  );
});

test('package subprocesses never inherit the installed-manifest signing key', () => {
  const result = __testing__.runChecked(process.execPath, [
    '-e',
    "process.stdout.write(process.env.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM ?? '')"
  ], {
    env: {
      ...process.env,
      OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM: 'must-not-cross-process'
    }
  });
  assert.equal(result.stdout, '');
});

test('Linux toolchain and native test runner require final RPM extraction tools', () => {
  const dockerfile = fs.readFileSync(path.join(repoRoot, 'tools/linux-toolchain/Dockerfile'), 'utf8');
  const smoke = fs.readFileSync(path.join(repoRoot, 'tools/linux-toolchain/smoke.sh'), 'utf8');
  const nativeRunner = fs.readFileSync(
    path.join(repoRoot, 'scripts/linux-port/run-linux-native-tests.sh'),
    'utf8'
  );
  assert.match(dockerfile, /\n        cpio \\\n/u);
  assert.match(dockerfile, /ATTESTD_RUST_TOOLCHAIN=1\.94\.0/u);
  assert.match(smoke, /command -v rpm2cpio[\s\S]*cpio --version/u);
  assert.match(smoke, /rustc \+1\.94\.0 --version/u);
  assert.match(
    nativeRunner,
    /OPENBURNBAR_REQUIRE_REAL_RPM_TOOLS=1[\s\S]*real RPM assembly preserves/u
  );
  assert.match(nativeRunner, /RUSTUP_TOOLCHAIN=1\.94\.0/u);
});

test('native package root contains broker assets and a self-excluding measurement manifest', () => {
  const f = fixture();
  const staged = stageNativeLinuxPackageRoot(stageOptions(f));
  const manifestPath = path.join(
    staged.root,
    'usr/share/openburnbar/attestation',
    INSTALLED_RELEASE_MANIFEST_NAME
  );
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

  assert.equal(manifest.packageFormat, 'deb');
  assert.equal(manifest.installedFilesRootSha256.length, 64);
  assert.equal(staged.releaseDigestSha256.length, 64);
  assert.ok(manifest.files.some((file) => file.path === '/usr/libexec/openburnbar-attestd'));
  assert.ok(manifest.files.some((file) => file.path === '/usr/libexec/openburnbar-attestd-activation-ready'));
  assert.ok(manifest.files.some((file) => file.path === '/usr/libexec/openburnbar-restart-active-user-daemons'));
  assert.ok(manifest.files.some((file) => file.path === '/usr/bin/openburnbar-daemon'));
  assert.equal(manifest.authorizedClients[0].sha256,
    manifest.files.find((file) => file.path === '/usr/bin/openburnbar-daemon').sha256);
  assert.ok(manifest.files.every((file) => file.path !== `/${path.relative(staged.root, manifestPath)}`));
  assert.equal(fs.statSync(path.join(staged.root, 'usr/libexec/openburnbar-attestd')).mode & 0o777, 0o755);
  assert.equal(fs.statSync(path.join(staged.root, 'usr/lib/systemd/system/openburnbar-attestd.socket')).mode & 0o777, 0o644);
  assert.equal(fs.statSync(staged.signaturePath).size, 64);
  fs.rmSync(f.root, { recursive: true, force: true });
});

test('manifest digest and file root change when a measured binary changes', () => {
  const f = fixture();
  const root = path.join(f.root, 'manifest-root');
  fs.mkdirSync(path.join(root, 'usr/bin'), { recursive: true });
  const binary = path.join(root, 'usr/bin/openburnbar-daemon');
  fs.writeFileSync(binary, 'one', { mode: 0o755 });
  const first = createInstalledReleaseManifest({
    root,
    version: '1.0.0',
    gitCommit: 'b'.repeat(40),
    architecture: 'aarch64',
    packageType: 'rpm'
  });
  fs.writeFileSync(binary, 'two');
  const second = createInstalledReleaseManifest({
    root,
    version: '1.0.0',
    gitCommit: 'b'.repeat(40),
    architecture: 'aarch64',
    packageType: 'rpm'
  });
  assert.notEqual(first.releaseDigestSha256, second.releaseDigestSha256);
  assert.notEqual(first.manifest.installedFilesRootSha256, second.manifest.installedFilesRootSha256);
  fs.rmSync(f.root, { recursive: true, force: true });
});

test('package staging rejects a signing key that does not match the packaged trust root', () => {
  const f = fixture();
  const { privateKey } = crypto.generateKeyPairSync('ed25519');
  const wrongPrivateKey = privateKey.export({ type: 'pkcs8', format: 'pem' });
  assert.throws(() => stageNativeLinuxPackageRoot({
    ...stageOptions(f),
    privateKeyPem: wrongPrivateKey
  }), /does not match packaged public key/);
  fs.rmSync(f.root, { recursive: true, force: true });
});

test('payload rejects symlinks that escape the package root', () => {
  const f = fixture();
  const root = path.join(f.root, 'escape-root');
  fs.mkdirSync(path.join(root, 'usr/lib/openburnbar'), { recursive: true });
  fs.symlinkSync('/etc/shadow', path.join(root, 'usr/lib/openburnbar/escape'));
  assert.throws(() => createInstalledReleaseManifest({
    root,
    version: '1.0.0',
    gitCommit: 'c'.repeat(40),
    architecture: 'x86_64',
    packageType: 'deb'
  }), /symlink escapes root/);
  fs.rmSync(f.root, { recursive: true, force: true });
});

test('RPM ownership list avoids claiming shared system directories', () => {
  const f = fixture();
  const staged = stageNativeLinuxPackageRoot(stageOptions(f, 'rpm'));
  const owned = rpmOwnedPaths(staged.root);
  assert.ok(owned.includes('/usr/bin/openburnbar-linux-desktop'));
  assert.ok(owned.includes('%dir /usr/lib/openburnbar'));
  assert.ok(!owned.includes('%dir /usr'));
  assert.ok(!owned.includes('%dir /usr/bin'));
  fs.rmSync(f.root, { recursive: true, force: true });
});

test('Debian assembly writes control metadata and lifecycle scripts before invoking dpkg-deb', () => {
  const f = fixture();
  const staged = stageNativeLinuxPackageRoot(stageOptions(f, 'deb'));
  const postinst = path.join(f.root, 'postinst');
  fs.writeFileSync(postinst, '#!/bin/sh\nset -eu\nsystemctl daemon-reload\n');
  const output = path.join(f.root, 'out', 'OpenBurnBar_1.2.3_amd64.deb');
  const calls = [];
  buildDebPackage({
    root: staged.root,
    output,
    version: '1.2.3',
    architecture: 'x86_64',
    scripts: { postinst },
    runner(command, args) {
      calls.push([command, args]);
      fs.mkdirSync(path.dirname(output), { recursive: true });
      fs.writeFileSync(output, 'deb');
    }
  });
  assert.deepEqual(calls, [['dpkg-deb', ['--root-owner-group', '--build', staged.root, output]]]);
  const control = fs.readFileSync(path.join(staged.root, 'DEBIAN/control'), 'utf8');
  assert.match(control, /Package: open-burn-bar/);
  assert.match(control, /Architecture: amd64/);
  assert.match(control, /Depends: .*libwebkit2gtk-4\.1-0/);
  assert.match(control, /Depends: .*libayatana-appindicator3-1/);
  assert.equal(fs.statSync(path.join(staged.root, 'DEBIAN/postinst')).mode & 0o777, 0o755);
  fs.rmSync(f.root, { recursive: true, force: true });
});

test('RPM assembly emits a bounded spec with lifecycle sections and copies one result', () => {
  const f = fixture();
  const staged = stageNativeLinuxPackageRoot(stageOptions(f, 'rpm'));
  const post = path.join(f.root, 'rpm-post');
  fs.writeFileSync(post, '#!/bin/sh\nset -eu\nsystemctl daemon-reload\n');
  const work = path.join(f.root, 'rpm-work');
  const out = path.join(f.root, 'out');
  const calls = [];
  const result = buildRpmPackage({
    root: staged.root,
    outputDirectory: out,
    workDirectory: work,
    version: '1.2.3',
    architecture: 'aarch64',
    scripts: { post },
    extractor(_rpm, destination) {
      fs.cpSync(staged.root, destination, { recursive: true, preserveTimestamps: false });
    },
    runner(command, args) {
      calls.push([command, args]);
      if (command === 'tar') fs.writeFileSync(args[args.indexOf('-czf') + 1], 'tar');
      if (command === 'rpmbuild') {
        const rpm = path.join(work, 'RPMS/aarch64/open-burn-bar-1.2.3-1.aarch64.rpm');
        fs.mkdirSync(path.dirname(rpm), { recursive: true });
        fs.writeFileSync(rpm, 'rpm');
      }
    }
  });
  assert.equal(result, path.join(out, 'OpenBurnBar-1.2.3-1.aarch64.rpm'));
  const spec = fs.readFileSync(path.join(work, 'SPECS/open-burn-bar.spec'), 'utf8');
  assert.match(spec, /BuildArch: aarch64/);
  assert.match(spec, /%global debug_package %\{nil\}/);
  assert.match(spec, /Requires: .*webkit2gtk4\.1/);
  assert.match(spec, /Requires: .*libayatana-appindicator-gtk3/);
  assert.match(spec, /Requires\(post\): systemd/);
  assert.match(spec, /%post\nset -eu/);
  assert.match(spec, /%files -f %\{SOURCE1\}/);
  assert.deepEqual(calls.map(([command]) => command), ['tar', 'rpmbuild']);
  const rpmArgs = calls.find(([command]) => command === 'rpmbuild')[1];
  assert.deepEqual(
    rpmArgs.slice(rpmArgs.indexOf('--define', 1), rpmArgs.indexOf('--target')),
    [
      '--define', '__os_install_post %{nil}',
      '--define', '_build_id_links none'
    ]
  );
  fs.rmSync(f.root, { recursive: true, force: true });
});

test('RPM assembly rejects mutation of a signed ELF sentinel in the final payload', () => {
  const f = fixture();
  const elfSentinel = Buffer.concat([
    Buffer.from([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00]),
    Buffer.from('OPENBURNBAR_RPM_BYTE_PRESERVATION_SENTINEL\0', 'utf8')
  ]);
  fs.writeFileSync(f.files.daemon, elfSentinel, { mode: 0o755 });
  const staged = stageNativeLinuxPackageRoot(stageOptions(f, 'rpm'));
  const work = path.join(f.root, 'rpm-mutation-work');
  const out = path.join(f.root, 'rpm-mutation-out');

  assert.throws(() => buildRpmPackage({
    root: staged.root,
    outputDirectory: out,
    workDirectory: work,
    version: '1.2.3',
    architecture: 'x86_64',
    scripts: {},
    runner(command, args) {
      if (command === 'tar') fs.writeFileSync(args[args.indexOf('-czf') + 1], 'tar');
      if (command === 'rpmbuild') {
        const rpm = path.join(work, 'RPMS/x86_64/open-burn-bar-1.2.3-1.x86_64.rpm');
        fs.mkdirSync(path.dirname(rpm), { recursive: true });
        fs.writeFileSync(rpm, 'rpm');
      }
    },
    extractor(_rpm, destination) {
      fs.cpSync(staged.root, destination, { recursive: true, preserveTimestamps: false });
      const extractedDaemon = path.join(destination, 'usr/bin/openburnbar-daemon');
      const mutated = fs.readFileSync(extractedDaemon)
        .subarray(0, 8);
      fs.writeFileSync(extractedDaemon, mutated, { mode: 0o755 });
    }
  }), /RPM payload files do not exactly match the signed installed manifest/);
  assert.ok(elfSentinel.includes(Buffer.from('OPENBURNBAR_RPM_BYTE_PRESERVATION_SENTINEL')));
  fs.rmSync(f.root, { recursive: true, force: true });
});

const rpmToolsAvailable = process.platform === 'linux'
  && ['rpmbuild', 'rpm2cpio', 'cpio'].every((command) =>
    spawnSync('sh', ['-lc', `command -v ${command}`], { stdio: 'ignore' }).status === 0);
const requireRealRpmTools = process.env.OPENBURNBAR_REQUIRE_REAL_RPM_TOOLS === '1';

test('real RPM assembly preserves a mutation-sensitive ELF payload byte for byte', {
  skip: !rpmToolsAvailable && !requireRealRpmTools
}, () => {
  assert.ok(
    rpmToolsAvailable,
    'OPENBURNBAR_REQUIRE_REAL_RPM_TOOLS requires rpmbuild, rpm2cpio, and cpio'
  );
  const f = fixture();
  const elfSentinel = Buffer.from('OPENBURNBAR_REAL_RPM_ELF_SENTINEL\0', 'utf8');
  fs.copyFileSync('/bin/true', f.files.daemon);
  fs.appendFileSync(f.files.daemon, elfSentinel);
  fs.chmodSync(f.files.daemon, 0o755);
  const architecture = process.arch === 'arm64' ? 'aarch64' : 'x86_64';
  const staged = stageNativeLinuxPackageRoot({
    ...stageOptions(f, 'rpm'),
    architecture
  });
  const result = buildRpmPackage({
    root: staged.root,
    outputDirectory: path.join(f.root, 'real-rpm-out'),
    workDirectory: path.join(f.root, 'real-rpm-work'),
    version: '1.2.3',
    architecture,
    scripts: {}
  });
  assert.ok(fs.existsSync(result));
  assert.ok(fs.statSync(result).size > elfSentinel.length);
  fs.rmSync(f.root, { recursive: true, force: true });
});
