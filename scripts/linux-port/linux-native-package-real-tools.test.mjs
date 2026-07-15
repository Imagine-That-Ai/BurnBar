import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  extractNativePackage,
  inspectNativePackageMetadata
} from './lib/linux-native-package.mjs';

const supported = process.platform === 'linux'
  && typeof process.getuid === 'function'
  && process.getuid() === 0
  && ['dpkg-deb', 'rpmbuild', 'rpm', 'rpm2cpio', 'bsdtar'].every(toolAvailable);

test('real deb and rpm metadata and payload extraction preserve release identity', {
  skip: supported ? false : 'requires the root Linux release toolchain'
}, (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-package-tools-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const architecture = process.arch === 'arm64' ? 'aarch64' : 'x86_64';
  const debArchitecture = architecture === 'aarch64' ? 'arm64' : 'amd64';
  const deb = buildDeb(root, debArchitecture);
  const rpm = buildRpm(root, architecture);
  const expected = {
    packageName: 'open-burn-bar',
    packageVersion: '1.2.3',
    packageArchitecture: architecture
  };
  for (const [format, artifact] of [['deb', deb], ['rpm', rpm]]) {
    assert.deepEqual(inspectNativePackageMetadata(format, artifact), expected);
    const destination = path.join(root, `extract-${format}`);
    extractNativePackage(format, artifact, destination);
    const daemon = path.join(destination, 'usr/bin/openburnbar-daemon');
    assert.equal(fs.readFileSync(daemon, 'utf8'), 'fixture\n');
    const stat = fs.lstatSync(daemon);
    assert.equal(stat.uid, 0);
    assert.equal(stat.gid, 0);
    assert.equal(stat.mode & 0o777, 0o755);
    assert.match(
      fs.readFileSync(path.join(destination, 'etc/xdg/autostart/openburnbar.desktop'), 'utf8'),
      /Exec=openburnbar-linux-desktop --background/u
    );
  }
});

function toolAvailable(command) {
  return (process.env.PATH ?? '').split(path.delimiter).some((directory) => {
    try {
      fs.accessSync(path.join(directory, command), fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  if (result.error || result.status !== 0) {
    throw new Error(`${command} failed:\n${result.stdout ?? ''}\n${result.stderr ?? ''}`);
  }
}

function buildDeb(root, architecture) {
  const packageRoot = path.join(root, 'deb-package');
  fs.mkdirSync(path.join(packageRoot, 'DEBIAN'), { recursive: true });
  fs.mkdirSync(path.join(packageRoot, 'usr/bin'), { recursive: true });
  fs.mkdirSync(path.join(packageRoot, 'etc/xdg/autostart'), { recursive: true });
  fs.writeFileSync(path.join(packageRoot, 'DEBIAN/control'), [
    'Package: open-burn-bar',
    'Version: 1.2.3',
    `Architecture: ${architecture}`,
    'Maintainer: OpenBurnBar',
    'Description: native package fixture',
    ''
  ].join('\n'));
  const daemon = path.join(packageRoot, 'usr/bin/openburnbar-daemon');
  fs.writeFileSync(daemon, 'fixture\n', { mode: 0o755 });
  fs.chmodSync(daemon, 0o755);
  fs.writeFileSync(
    path.join(packageRoot, 'etc/xdg/autostart/openburnbar.desktop'),
    '[Desktop Entry]\nType=Application\nExec=openburnbar-linux-desktop --background\n'
  );
  const artifact = path.join(root, 'open-burn-bar.deb');
  run('dpkg-deb', ['--build', packageRoot, artifact]);
  return artifact;
}

function buildRpm(root, architecture) {
  const top = path.join(root, 'rpmbuild');
  for (const directory of ['BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS']) {
    fs.mkdirSync(path.join(top, directory), { recursive: true });
  }
  const spec = path.join(top, 'SPECS/open-burn-bar.spec');
  fs.writeFileSync(spec, [
    'Name: open-burn-bar',
    'Version: 1.2.3',
    'Release: 1',
    'Summary: native package fixture',
    'License: MIT',
    `BuildArch: ${architecture}`,
    '%description',
    'fixture',
    '%install',
    'mkdir -p %{buildroot}/usr/bin',
    'echo fixture > %{buildroot}/usr/bin/openburnbar-daemon',
    'chmod 755 %{buildroot}/usr/bin/openburnbar-daemon',
    'mkdir -p %{buildroot}/etc/xdg/autostart',
    "printf '[Desktop Entry]\\nType=Application\\nExec=openburnbar-linux-desktop --background\\n' > %{buildroot}/etc/xdg/autostart/openburnbar.desktop",
    'chmod 644 %{buildroot}/etc/xdg/autostart/openburnbar.desktop',
    '%files',
    '/usr/bin/openburnbar-daemon',
    '/etc/xdg/autostart/openburnbar.desktop',
    ''
  ].join('\n'));
  run('rpmbuild', ['--define', `_topdir ${top}`, '-bb', spec]);
  const artifacts = walk(path.join(top, 'RPMS')).filter((file) => file.endsWith('.rpm'));
  assert.equal(artifacts.length, 1);
  return artifacts[0];
}

function walk(root) {
  const files = [];
  const pending = [root];
  while (pending.length > 0) {
    const current = pending.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const file = path.join(current, entry.name);
      if (entry.isDirectory()) pending.push(file);
      else if (entry.isFile()) files.push(file);
    }
  }
  return files;
}
