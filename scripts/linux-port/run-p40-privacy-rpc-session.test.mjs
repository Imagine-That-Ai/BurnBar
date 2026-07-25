import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  P40_DEFAULT_RETENTION_RULES,
  P40_ENVIRONMENTS,
  P40_RETENTION_CONTRACT,
  P40_RPC_METHODS,
  P40_STORES
} from './lib/p40-privacy-proof.mjs';
import { SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';
import {
  buildSession,
  environmentIdentity,
  normalizeArchitecture,
  parseArguments,
  queryInstalledPackage,
  verifyDesktopSession
} from './run-p40-privacy-rpc-session.mjs';

const PRODUCER_SOURCE = fs.readFileSync(
  fileURLToPath(new URL('./run-p40-privacy-rpc-session.mjs', import.meta.url)),
  'utf8'
);

const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-aarch64';
const HEAD = 'a'.repeat(40);
const RUN_ID = '29351903622';
const DIGEST = `sha256:${'b'.repeat(64)}`;
const OPTIONS = {
  environmentId: ENVIRONMENT,
  targetHead: HEAD,
  candidateRunId: RUN_ID,
  candidateArtifactDigest: DIGEST,
  packageVersion: '1.2.3',
  manifestSha256: 'c'.repeat(64)
};

function runtimeFor(identity, versionId = identity.os.versionId ?? 'rolling') {
  return {
    architecture: identity.architecture,
    compositor: identity.compositor,
    desktop: identity.desktop,
    displayServer: identity.displayServer,
    os: { id: identity.os.id, versionId }
  };
}

function packageQueryOutput(identity, mutation = {}) {
  const name = mutation.name ?? identity.packageName;
  const version = mutation.version ?? '1.2.3';
  const architecture = mutation.architecture ?? identity.architecture;
  if (identity.packageFormat === 'deb') {
    const nativeArchitecture = architecture === 'x86_64' ? 'amd64' : architecture === 'aarch64' ? 'arm64' : architecture;
    return `install ok installed\t${version}\t${nativeArchitecture}\t${name}\n`;
  }
  if (identity.packageFormat === 'rpm') return `${name}\t${version}\t${architecture}\n`;
  return `Name            : ${name}\nVersion         : ${version}-1\nArchitecture    : ${architecture}\n`;
}

function packageRunner(output, calls) {
  return (command, args, options) => {
    calls.push({ args, command, options });
    return { error: null, status: 0, stderr: '', stdout: output };
  };
}

function desktopDependencies(identity, mutation = {}) {
  const desktopPid = '101';
  const compositorPid = identity.compositorProcess === identity.desktopProcess ? desktopPid : '102';
  const displayVariable = identity.displayServer === 'Wayland' ? 'WAYLAND_DISPLAY' : 'DISPLAY';
  const desktopEnvironment = {
    XDG_CURRENT_DESKTOP: mutation.processDesktop ?? identity.desktop,
    XDG_SESSION_TYPE: (mutation.processSession ?? identity.displayServer).toLowerCase(),
    [displayVariable]: mutation.missingDisplay ? '' : identity.displayServer === 'Wayland' ? 'wayland-1' : ':0'
  };
  const compositorEnvironment = {
    XDG_SESSION_TYPE: identity.displayServer.toLowerCase()
  };
  const osRelease = identity.os.id === 'ubuntu'
    ? { ID: 'ubuntu', VERSION_ID: mutation.osVersion ?? '24.04' }
    : identity.os.id === 'fedora'
      ? { ID: 'fedora', VERSION_ID: mutation.osVersion ?? '42' }
      : { BUILD_ID: mutation.osVersion ?? 'rolling', ID: 'arch' };
  const runner = (command, args) => {
    if (command === '/usr/bin/loginctl' && args[0] === 'list-sessions') {
      return { error: null, status: 0, stderr: '', stdout: '7 1000 burnbar seat0 tty2\n' };
    }
    if (command === '/usr/bin/loginctl' && args[0] === 'show-session') {
      const type = (mutation.logindSession ?? identity.displayServer).toLowerCase();
      const desktop = mutation.logindDesktop ?? identity.desktop;
      return {
        error: null,
        status: 0,
        stderr: '',
        stdout: `Type=${type}\nDesktop=${desktop}\nClass=user\nActive=yes\nRemote=no\nState=active\n`
      };
    }
    if (command === '/usr/bin/pgrep') {
      const processName = args.at(-1);
      if (mutation.missingCompositor && processName === identity.compositorProcess) {
        return { error: null, status: 1, stderr: '', stdout: '' };
      }
      if (processName === identity.desktopProcess) {
        return { error: null, status: 0, stderr: '', stdout: `${desktopPid}\n` };
      }
      if (processName === identity.compositorProcess) {
        return { error: null, status: 0, stderr: '', stdout: `${compositorPid}\n` };
      }
    }
    throw new Error(`unexpected command: ${command} ${args.join(' ')}`);
  };
  return {
    architecture: mutation.architecture ?? (identity.architecture === 'x86_64' ? 'x64' : 'arm64'),
    getuid: () => 1000,
    osRelease,
    readProcessEnvironment: (pid) => pid === desktopPid ? desktopEnvironment : compositorEnvironment,
    runner
  };
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
      appliedRules: P40_STORES.map((store) => ({ store, maxAgeSeconds: 3_600, maxBytes: 65_536 })),
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

test('argument parser requires candidate identity and absolute runtime paths', () => {
  const args = [
    '--socket', '/run/user/1000/openburnbar/daemon.sock',
    '--token-file', '/home/burnbar/.cache/openburnbar-p40-1/support/daemon-socket-auth-token',
    '--output-root', '/home/burnbar/.cache/openburnbar-p40-1/evidence',
    '--environment', ENVIRONMENT,
    '--target-head', HEAD,
    '--candidate-run-id', RUN_ID,
    '--candidate-artifact-digest', DIGEST,
    '--package-version', '1.2.3',
    '--manifest-sha256', 'c'.repeat(64)
  ];
  const parsed = parseArguments(args);
  assert.equal(parsed.environmentId, ENVIRONMENT);
  assert.throws(() => parseArguments(args.slice(0, -2)), /--manifest-sha256 is required/u);
  assert.throws(() => parseArguments(args.map((value) => value === '/run/user/1000/openburnbar/daemon.sock' ? 'relative.sock' : value)), /socket must be absolute/u);
  assert.throws(() => parseArguments([...args, '--unknown', 'value']), /invalid argument/u);
});

test('live producer uses the installed authorized CLI peer', () => {
  assert.match(PRODUCER_SOURCE, /const CLI_BINARY_PATH = '\/usr\/bin\/openburnbar-cli';/u);
  assert.match(PRODUCER_SOURCE, /spawnSync\(CLI_BINARY_PATH, \['privacy-rpc'\]/u);
  assert.match(PRODUCER_SOURCE, /OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE/u);
  assert.doesNotMatch(PRODUCER_SOURCE, /net\.createConnection/u);
  assert.doesNotMatch(PRODUCER_SOURCE, /daemon\.health/u);
  assert.match(PRODUCER_SOURCE, /DESKTOP_RUNTIMES/u);
  assert.match(PRODUCER_SOURCE, /kwin_wayland/u);
  assert.match(PRODUCER_SOURCE, /WAYLAND_DISPLAY/u);
  assert.match(PRODUCER_SOURCE, /queryInstalledPackage/u);
  assert.match(PRODUCER_SOURCE, /trustedSystemExecutable/u);
  assert.match(PRODUCER_SOURCE, /'\/usr\/bin\/dpkg-query'/u);
  assert.match(PRODUCER_SOURCE, /'\/usr\/bin\/rpm'/u);
  assert.match(PRODUCER_SOURCE, /'\/usr\/bin\/pacman'/u);
  assert.match(PRODUCER_SOURCE, /delete environment\[variable\]/u);
  assert.match(PRODUCER_SOURCE, /manifest\.packageArchitecture === identity\.architecture/u);
  assert.match(PRODUCER_SOURCE, /manifest\.packageFormat === identity\.packageFormat/u);
  assert.match(PRODUCER_SOURCE, /manifest\.packageName === identity\.packageName/u);
  assert.doesNotMatch(PRODUCER_SOURCE, /expected\.format === 'deb'/u);
  assert.doesNotMatch(PRODUCER_SOURCE, /architecture === 'arm64'/u);
});

test('canonical environment identities cover every package, architecture, desktop, display, and compositor row', () => {
  assert.deepEqual(Object.keys(P40_ENVIRONMENTS), [...SUPPORT_ENVIRONMENTS]);
  const expected = {
    'ubuntu-24.04-gnome-x11-x86_64': ['x86_64', 'deb', 'open-burn-bar', 'GNOME', 'X11', 'Mutter'],
    'ubuntu-24.04-gnome-x11-aarch64': ['aarch64', 'deb', 'open-burn-bar', 'GNOME', 'X11', 'Mutter'],
    'ubuntu-24.04-gnome-wayland-x86_64': ['x86_64', 'deb', 'open-burn-bar', 'GNOME', 'Wayland', 'Mutter'],
    'ubuntu-24.04-gnome-wayland-aarch64': ['aarch64', 'deb', 'open-burn-bar', 'GNOME', 'Wayland', 'Mutter'],
    'fedora-kde-wayland-x86_64': ['x86_64', 'rpm', 'open-burn-bar', 'KDE Plasma', 'Wayland', 'KWin'],
    'fedora-kde-wayland-aarch64': ['aarch64', 'rpm', 'open-burn-bar', 'KDE Plasma', 'Wayland', 'KWin'],
    'arch-sway-wayland-x86_64': ['x86_64', 'arch', 'openburnbar', 'Sway/wlroots', 'Wayland', 'Sway']
  };
  for (const environmentId of SUPPORT_ENVIRONMENTS) {
    const identity = environmentIdentity(environmentId);
    assert.deepEqual([
      identity.architecture,
      identity.packageFormat,
      identity.packageName,
      identity.desktop,
      identity.displayServer,
      identity.compositor
    ], expected[environmentId]);
  }
  assert.throws(() => environmentIdentity('not-a-canonical-row'), /unsupported P-40 environment/u);
  assert.equal(normalizeArchitecture('x64'), 'x86_64');
  assert.equal(normalizeArchitecture('amd64'), 'x86_64');
  assert.equal(normalizeArchitecture('arm64'), 'aarch64');
  assert.throws(() => normalizeArchitecture('i686'), /unsupported Linux architecture/u);
});

test('installed package queries select DEB, RPM, and Arch managers for both architectures and reject mutations', () => {
  for (const environmentId of SUPPORT_ENVIRONMENTS) {
    const identity = environmentIdentity(environmentId);
    const calls = [];
    const observed = queryInstalledPackage(
      identity,
      '1.2.3',
      packageRunner(packageQueryOutput(identity), calls)
    );
    assert.deepEqual(observed, {
      architecture: identity.architecture,
      format: identity.packageFormat,
      manager: identity.manager,
      name: identity.packageName,
      version: '1.2.3'
    });
    assert.equal(calls.length, 1);
    const expectedCommand = identity.packageFormat === 'deb' ? '/usr/bin/dpkg-query'
      : identity.packageFormat === 'rpm' ? '/usr/bin/rpm' : '/usr/bin/pacman';
    assert.equal(calls[0].command, expectedCommand);
    assert.equal(calls[0].args.at(-1), identity.packageName);
    assert.equal(calls[0].options.env.LC_ALL, 'C');
    for (const variable of ['DPKG_ADMINDIR', 'DPKG_ROOT', 'LD_AUDIT', 'LD_LIBRARY_PATH', 'LD_PRELOAD', 'RPM_CONFIGDIR']) {
      assert.equal(calls[0].options.env[variable], undefined);
    }
  }

  for (const environmentId of [
    'ubuntu-24.04-gnome-x11-x86_64',
    'ubuntu-24.04-gnome-x11-aarch64',
    'fedora-kde-wayland-x86_64',
    'fedora-kde-wayland-aarch64',
    'arch-sway-wayland-x86_64'
  ]) {
    const identity = environmentIdentity(environmentId);
    const oppositeArchitecture = identity.architecture === 'x86_64' ? 'aarch64' : 'x86_64';
    for (const [mutation, error] of [
      [{ name: 'substitute-package' }, /package name/u],
      [{ version: '9.9.9' }, /package version/u],
      [{ architecture: oppositeArchitecture }, /package architecture/u]
    ]) {
      assert.throws(
        () => queryInstalledPackage(
          identity,
          '1.2.3',
          packageRunner(packageQueryOutput(identity, mutation), [])
        ),
        error
      );
    }
  }
});

test('live runtime observation binds every canonical row to real logind, desktop, display, and compositor processes', () => {
  for (const environmentId of SUPPORT_ENVIRONMENTS) {
    const identity = environmentIdentity(environmentId);
    const observed = verifyDesktopSession(identity, desktopDependencies(identity));
    assert.deepEqual(observed, runtimeFor(
      identity,
      identity.os.id === 'fedora' ? '42' : identity.os.id === 'arch' ? 'rolling' : '24.04'
    ));
  }

  const kde = environmentIdentity('fedora-kde-wayland-aarch64');
  const sway = environmentIdentity('arch-sway-wayland-x86_64');
  const gnome = environmentIdentity('ubuntu-24.04-gnome-x11-x86_64');
  assert.throws(
    () => verifyDesktopSession(kde, desktopDependencies(kde, { architecture: 'x64' })),
    /architecture/u
  );
  assert.throws(
    () => verifyDesktopSession(kde, desktopDependencies(kde, { logindSession: 'x11' })),
    /no active local desktop/u
  );
  assert.throws(
    () => verifyDesktopSession(sway, desktopDependencies(sway, { logindDesktop: 'GNOME' })),
    /no active local desktop/u
  );
  assert.throws(
    () => verifyDesktopSession(gnome, desktopDependencies(gnome, { missingDisplay: true })),
    /no active local desktop/u
  );
  assert.throws(
    () => verifyDesktopSession(kde, desktopDependencies(kde, { missingCompositor: true })),
    /no active local desktop/u
  );
  assert.throws(
    () => verifyDesktopSession(gnome, desktopDependencies(gnome, { osVersion: '22.04' })),
    /OS version/u
  );
});

test('session builder emits exactly the redacted live P-40 schema for every canonical row and rejects identity mutation', () => {
  for (const environmentId of SUPPORT_ENVIRONMENTS) {
    const identity = environmentIdentity(environmentId);
    const options = { ...OPTIONS, environmentId };
    const runtime = runtimeFor(
      identity,
      identity.os.id === 'fedora' ? '42' : identity.os.id === 'arch' ? 'rolling' : '24.04'
    );
    const session = buildSession(
      options,
      identity,
      options.packageVersion,
      options.manifestSha256,
      observations(),
      runtime
    );
    assert.equal(session.capture.mode, 'installed-rpc');
    assert.equal(session.capture.architecture, identity.architecture);
    assert.equal(session.capture.os.versionId, runtime.os.versionId);
    assert.equal(session.package.format, identity.packageFormat);
    assert.deepEqual(session.daemon.rpcMethods, [...P40_RPC_METHODS]);
    assert.deepEqual(session.contract.defaultRetentionRules, [...P40_DEFAULT_RETENTION_RULES]);
    assert.equal(session.contract.confirmationPhrase, P40_RETENTION_CONTRACT.confirmationPhrase);
    assert.equal(session.package.source, 'signed-installed-candidate');
    assert.equal(session.daemon.source, 'installed-candidate-daemon');
    assert.doesNotMatch(JSON.stringify(session), /"(?:token|passphrase|absolutePath|contents|destinationPath|storePath|rawBytes)"/iu);
  }

  const identity = environmentIdentity(ENVIRONMENT);
  const runtime = runtimeFor(identity, '24.04');
  const session = buildSession(
    OPTIONS,
    identity,
    OPTIONS.packageVersion,
    OPTIONS.manifestSha256,
    observations(),
    runtime
  );
  assert.equal(session.capture.session, 'X11');
  assert.throws(() => buildSession(
    { ...OPTIONS, candidateArtifactDigest: 'not-a-digest' },
    identity,
    OPTIONS.packageVersion,
    OPTIONS.manifestSha256,
    observations(),
    runtime
  ), /candidate artifact digest/u);
  for (const [mutatedRuntime, error] of [
    [{ ...runtime, architecture: 'x86_64' }, /architecture/u],
    [{ ...runtime, desktop: 'KDE Plasma' }, /desktop/u],
    [{ ...runtime, displayServer: 'Wayland' }, /display server/u],
    [{ ...runtime, compositor: 'KWin' }, /compositor/u],
    [{ ...runtime, os: { ...runtime.os, id: 'fedora' } }, /OS id/u],
    [{ ...runtime, os: { ...runtime.os, versionId: '22.04' } }, /OS version/u]
  ]) {
    assert.throws(() => buildSession(
      OPTIONS,
      identity,
      OPTIONS.packageVersion,
      OPTIONS.manifestSha256,
      observations(),
      mutatedRuntime
    ), error);
  }
});
