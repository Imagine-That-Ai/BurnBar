#!/usr/bin/env node
/**
 * Rebuild Linux package payloads so deb/rpm (and optional AppImage inject)
 * ship the branch daemon, openburnbar-daemon-launch, systemd unit, and the
 * Swift 6.1 runtime under /opt/openburnbar/lib/swift.
 *
 * Intended to run on a Linux aarch64 guest with dpkg-deb + fpm (or rpmbuild).
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const outDir = path.resolve(
  process.env.OPENBURNBAR_LINUX_RELEASE_OUT ??
    path.join(root, 'docs/linux-port/evidence/mission-002-reanchor')
);
const artDir = path.join(outDir, 'artifacts');
const workRoot = path.join(outDir, '.package-rebuild-work');
const version = process.env.OPENBURNBAR_LINUX_PACKAGE_VERSION?.trim() || '0.1.0';

const daemonBin =
  process.env.OPENBURNBAR_LINUX_DAEMON_BIN?.trim() ||
  path.join(root, 'OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon');
const launchSrc = path.join(root, 'packaging/linux/openburnbar-daemon-launch.sh');
const serviceSrc = path.join(root, 'packaging/linux/openburnbar-daemon.service');
const desktopSrc = path.join(root, 'packaging/linux/openburnbar.desktop');
const swiftSrc =
  process.env.OPENBURNBAR_SWIFT_LIB_DIR?.trim() ||
  [
    '/opt/openburnbar/lib/swift',
    '/opt/swift-6.1-RELEASE-ubuntu24.04-aarch64/usr/lib/swift/linux',
    '/opt/swift/usr/lib/swift/linux'
  ].find((p) => fs.existsSync(p));

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, {
    cwd: opts.cwd ?? root,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, ...(opts.env ?? {}) }
  });
  if ((r.status ?? 1) !== 0) {
    const msg = `${cmd} ${args.join(' ')}\n${r.stdout ?? ''}\n${r.stderr ?? ''}`;
    if (!opts.allowFail) throw new Error(msg);
  }
  return r;
}

function mustExist(p, label) {
  if (!fs.existsSync(p)) throw new Error(`${label} missing: ${p}`);
}

mustExist(daemonBin, 'daemon binary');
mustExist(launchSrc, 'launch script');
mustExist(serviceSrc, 'systemd unit');
if (!swiftSrc) throw new Error('Swift runtime dir not found (set OPENBURNBAR_SWIFT_LIB_DIR)');

fs.rmSync(workRoot, { recursive: true, force: true });
fs.mkdirSync(artDir, { recursive: true });

const tree = path.join(workRoot, 'root');
const paths = {
  bin: path.join(tree, 'usr/bin'),
  libexec: path.join(tree, 'usr/libexec'),
  systemd: path.join(tree, 'usr/lib/systemd/user'),
  apps: path.join(tree, 'usr/share/applications'),
  swift: path.join(tree, 'opt/openburnbar/lib/swift'),
  lib: path.join(tree, 'opt/openburnbar/lib')
};
for (const d of Object.values(paths)) fs.mkdirSync(d, { recursive: true });

fs.copyFileSync(daemonBin, path.join(paths.bin, 'openburnbar-daemon'));
fs.chmodSync(path.join(paths.bin, 'openburnbar-daemon'), 0o755);
fs.copyFileSync(launchSrc, path.join(paths.libexec, 'openburnbar-daemon-launch'));
fs.chmodSync(path.join(paths.libexec, 'openburnbar-daemon-launch'), 0o755);
fs.copyFileSync(serviceSrc, path.join(paths.systemd, 'openburnbar-daemon.service'));
if (fs.existsSync(desktopSrc)) {
  fs.copyFileSync(desktopSrc, path.join(paths.apps, 'dev.openburnbar.OpenBurnBar.desktop'));
}

// Copy Swift shared libs (runtime only — .so* and support)
run('rsync', ['-a', '--delete', `${swiftSrc}/`, `${paths.swift}/`]);

// Prefer packaged sqlcipher soname next to swift if present on host package layout
const sqlcipherCandidates = [
  '/opt/openburnbar/lib/libsqlcipher.so.0',
  '/opt/openburnbar/lib/libsqlcipher.so.0.8.6',
  '/opt/openburnbar/lib/libsqlcipher.so'
];
for (const c of sqlcipherCandidates) {
  if (fs.existsSync(c)) {
    fs.copyFileSync(c, path.join(paths.lib, path.basename(c)));
  }
}

function buildDeb() {
  const debRoot = path.join(workRoot, 'deb');
  fs.rmSync(debRoot, { recursive: true, force: true });
  fs.mkdirSync(debRoot, { recursive: true });
  run('cp', ['-a', `${tree}/.`, debRoot]);
  const debian = path.join(debRoot, 'DEBIAN');
  fs.mkdirSync(debian, { recursive: true });
  const installedSize = Math.max(1, Math.ceil(Number(run('du', ['-sk', debRoot]).stdout.split(/\s+/)[0]) || 1));
  fs.writeFileSync(
    path.join(debian, 'control'),
    [
      'Package: open-burn-bar',
      `Version: ${version}`,
      'Section: utils',
      'Priority: optional',
      'Architecture: arm64',
      'Maintainer: OpenBurnBar <ops@openburnbar.dev>',
      `Installed-Size: ${installedSize}`,
      'Depends: libc6, libsecret-tools',
      'Recommends: gnome-keyring | libkf5wallet-bin | libkf6wallet-bin',
      'Description: OpenBurnBar Linux desktop + daemon (product parity payload)',
      ' Ships openburnbar-daemon, launch wrapper, systemd user unit, and Swift runtime.',
      ''
    ].join('\n')
  );
  const out = path.join(artDir, `OpenBurnBar_${version}_arm64.deb`);
  run('dpkg-deb', ['-b', debRoot, out]);
  // Stage for discoverBundleArtifacts
  const bundleDeb = path.join(root, 'apps/linux-desktop/src-tauri/target/release/bundle/deb');
  fs.mkdirSync(bundleDeb, { recursive: true });
  fs.copyFileSync(out, path.join(bundleDeb, path.basename(out)));
  return out;
}

function buildRpm() {
  const out = path.join(artDir, `OpenBurnBar-${version}-1.aarch64.rpm`);
  fs.rmSync(out, { force: true });
  if (spawnSync('fpm', ['--version'], { encoding: 'utf8' }).status === 0) {
    run('fpm', [
      '-s',
      'dir',
      '-t',
      'rpm',
      '-n',
      'open-burn-bar',
      '-v',
      version,
      '--iteration',
      '1',
      '-a',
      'aarch64',
      '--rpm-os',
      'linux',
      '-C',
      tree,
      '-p',
      out,
      '--force',
      '--description',
      'OpenBurnBar Linux desktop + daemon (product parity payload)',
      '--depends',
      'libsecret',
      '.'
    ]);
  } else if (spawnSync('alien', ['--version'], { encoding: 'utf8' }).status === 0) {
    // alien converts deb → rpm
    const deb = path.join(artDir, `OpenBurnBar_${version}_arm64.deb`);
    mustExist(deb, 'deb for alien');
    const alienDir = path.join(workRoot, 'alien');
    fs.rmSync(alienDir, { recursive: true, force: true });
    fs.mkdirSync(alienDir, { recursive: true });
    run('alien', ['--to-rpm', '--scripts', deb], { cwd: alienDir });
    const built = fs.readdirSync(alienDir).find((f) => f.endsWith('.rpm'));
    if (!built) throw new Error('alien did not produce rpm');
    fs.copyFileSync(path.join(alienDir, built), out);
  } else {
    throw new Error('Neither fpm nor alien available to build rpm');
  }
  const bundleRpm = path.join(root, 'apps/linux-desktop/src-tauri/target/release/bundle/rpm');
  fs.mkdirSync(bundleRpm, { recursive: true });
  fs.copyFileSync(out, path.join(bundleRpm, path.basename(out)));
  return out;
}

function injectAppImageIfPresent() {
  const appImage =
    process.env.OPENBURNBAR_LINUX_APPIMAGE?.trim() ||
    path.join(artDir, `OpenBurnBar_${version}_aarch64.AppImage`);
  if (!fs.existsSync(appImage)) {
    console.log(JSON.stringify({ appimage: 'skipped-missing', path: appImage }));
    return null;
  }
  const extractDir = path.join(workRoot, 'appimage-extract');
  fs.rmSync(extractDir, { recursive: true, force: true });
  fs.mkdirSync(extractDir, { recursive: true });
  fs.chmodSync(appImage, 0o755);
  // AppImage self-extract into cwd
  run(appImage, ['--appimage-extract'], { cwd: extractDir, allowFail: true });
  const squash = path.join(extractDir, 'squashfs-root');
  if (!fs.existsSync(squash)) {
    console.log(JSON.stringify({ appimage: 'extract-failed', path: appImage }));
    return null;
  }
  // Inject payload under usr/ and opt/
  for (const rel of ['usr/bin', 'usr/libexec', 'usr/lib/systemd/user', 'opt/openburnbar/lib/swift', 'opt/openburnbar/lib']) {
    fs.mkdirSync(path.join(squash, rel), { recursive: true });
  }
  fs.copyFileSync(path.join(paths.bin, 'openburnbar-daemon'), path.join(squash, 'usr/bin/openburnbar-daemon'));
  fs.chmodSync(path.join(squash, 'usr/bin/openburnbar-daemon'), 0o755);
  fs.copyFileSync(path.join(paths.libexec, 'openburnbar-daemon-launch'), path.join(squash, 'usr/libexec/openburnbar-daemon-launch'));
  fs.chmodSync(path.join(squash, 'usr/libexec/openburnbar-daemon-launch'), 0o755);
  fs.copyFileSync(path.join(paths.systemd, 'openburnbar-daemon.service'), path.join(squash, 'usr/lib/systemd/user/openburnbar-daemon.service'));
  run('rsync', ['-a', `${paths.swift}/`, path.join(squash, 'opt/openburnbar/lib/swift/')]);
  // Prefer appimagetool if present; otherwise leave extracted inject log and keep original AppImage
  // with a sidecar note — full repack needs appimagetool.
  const tool = spawnSync('appimagetool', ['--version'], { encoding: 'utf8' });
  if (tool.status === 0) {
    const rebuilt = path.join(artDir, `OpenBurnBar_${version}_aarch64.AppImage`);
    run('appimagetool', [squash, rebuilt]);
    fs.chmodSync(rebuilt, 0o755);
    const bundleAi = path.join(root, 'apps/linux-desktop/src-tauri/target/release/bundle/appimage');
    fs.mkdirSync(bundleAi, { recursive: true });
    fs.copyFileSync(rebuilt, path.join(bundleAi, path.basename(rebuilt)));
    return rebuilt;
  }
  // Without appimagetool: still ship daemon+runtime as required artifacts via deb/rpm;
  // annotate AppImage as desktop shell bundle that must pair with daemon package.
  fs.writeFileSync(
    path.join(artDir, 'AppImage-runtime-note.json'),
    JSON.stringify(
      {
        note: 'AppImage retained as desktop shell; daemon+Swift runtime are required deb/rpm co-install payload for product parity packaging.',
        injectedExtractPath: squash,
        hasDaemonInDebRpm: true
      },
      null,
      2
    ) + '\n'
  );
  return appImage;
}

// Also stage standalone daemon artifact
const daemonArtifact = path.join(artDir, `openburnbar-daemon-${version}-linux-aarch64`);
fs.copyFileSync(daemonBin, daemonArtifact);
fs.chmodSync(daemonArtifact, 0o755);
const daemonBuildPath = path.join(root, 'OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon');
fs.mkdirSync(path.dirname(daemonBuildPath), { recursive: true });
fs.copyFileSync(daemonBin, daemonBuildPath);
fs.chmodSync(daemonBuildPath, 0o755);

const deb = buildDeb();
const rpm = buildRpm();
const appimage = injectAppImageIfPresent();

const report = {
  generatedAt: new Date().toISOString(),
  deb,
  rpm,
  appimage,
  daemonArtifact,
  swiftSrc,
  contains: [
    'usr/bin/openburnbar-daemon',
    'usr/libexec/openburnbar-daemon-launch',
    'usr/lib/systemd/user/openburnbar-daemon.service',
    'opt/openburnbar/lib/swift'
  ],
  credentialStorage: {
    requiredCommand: 'secret-tool',
    primaryBackend: 'org.freedesktop.secrets',
    optionalBackend: 'kwallet-query',
    lockedBackendPolicy: 'fail-closed'
  }
};
fs.writeFileSync(path.join(outDir, 'package-rebuild-report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
