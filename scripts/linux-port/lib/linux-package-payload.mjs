import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function requireDirectory(candidate, label) {
  if (!candidate || !fs.existsSync(candidate) || !fs.statSync(candidate).isDirectory()) {
    throw new Error(`${label} directory not found: ${candidate || '(unset)'}`);
  }
  return path.resolve(candidate);
}

function requireFile(candidate, label) {
  if (!candidate || !fs.existsSync(candidate) || !fs.statSync(candidate).isFile()) {
    throw new Error(`${label} file not found: ${candidate || '(unset)'}`);
  }
  return path.resolve(candidate);
}

function requireRegularFile(candidate, label) {
  if (!candidate || !fs.existsSync(candidate)) {
    throw new Error(`${label} file not found: ${candidate || '(unset)'}`);
  }
  const stat = fs.lstatSync(candidate);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`${label} must be a regular file: ${candidate}`);
  }
  return path.resolve(candidate);
}

export function swiftTargetInfo(command = 'swift') {
  const result = spawnSync(command, ['-print-target-info'], {
    encoding: 'utf8',
    maxBuffer: 4 * 1024 * 1024
  });
  if ((result.status ?? 1) !== 0) {
    throw new Error(`swift -print-target-info failed: ${result.stderr || result.stdout}`);
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`swift -print-target-info returned invalid JSON: ${error.message}`);
  }
}

export function resolveSwiftRuntimeDir({ env = process.env, targetInfo = null } = {}) {
  const candidates = [];
  if (env.OPENBURNBAR_SWIFT_LIB_DIR?.trim()) {
    candidates.push(env.OPENBURNBAR_SWIFT_LIB_DIR.trim());
  }
  const info = targetInfo ?? swiftTargetInfo();
  candidates.push(...(info.paths?.runtimeLibraryPaths ?? []));
  candidates.push('/usr/lib/swift/linux', '/usr/local/swift/usr/lib/swift/linux');
  const found = candidates.find((candidate) => candidate && fs.existsSync(candidate));
  return requireDirectory(found, 'Swift runtime');
}

export function resolveSqlcipherLibDir({ env = process.env } = {}) {
  const candidates = [];
  if (env.OPENBURNBAR_SQLCIPHER_LIB_DIR?.trim()) {
    candidates.push(env.OPENBURNBAR_SQLCIPHER_LIB_DIR.trim());
  }
  if (env.OPENBURNBAR_SQLCIPHER_PREFIX?.trim()) {
    candidates.push(path.join(env.OPENBURNBAR_SQLCIPHER_PREFIX.trim(), 'lib'));
  }
  candidates.push('/opt/openburnbar/sqlcipher/lib', '/usr/local/lib', '/usr/lib');
  const found = candidates.find((candidate) => {
    if (!candidate || !fs.existsSync(candidate)) return false;
    return fs.readdirSync(candidate).some((entry) => entry.startsWith('libsqlcipher.so'));
  });
  return requireDirectory(found, 'SQLCipher runtime');
}

export function resolveIrohNativeLibrary({ env = process.env } = {}) {
  const directory = env.OPENBURNBAR_LINUX_IROH_LIBRARY_DIR?.trim();
  if (!directory) {
    throw new Error('OPENBURNBAR_LINUX_IROH_LIBRARY_DIR is required for a shipping Linux package');
  }
  return requireRegularFile(
    path.join(directory, 'libopenburnbar_iroh.so'),
    'Linux iroh native runtime'
  );
}

const linuxResourceBundleName = 'OpenBurnBarCore_OpenBurnBarCore.resources';

export function resolveLinuxResourceBundle({ repoRoot, env = process.env } = {}) {
  const candidates = [];
  if (env.OPENBURNBAR_LINUX_RESOURCE_BUNDLE?.trim()) {
    candidates.push(env.OPENBURNBAR_LINUX_RESOURCE_BUNDLE.trim());
  }
  if (repoRoot) {
    const daemonBuildRoot = path.join(repoRoot, 'OpenBurnBarDaemon/.build');
    candidates.push(
      path.join(daemonBuildRoot, 'release', linuxResourceBundleName),
      path.join(daemonBuildRoot, 'aarch64-unknown-linux-gnu/release', linuxResourceBundleName),
      path.join(daemonBuildRoot, 'x86_64-unknown-linux-gnu/release', linuxResourceBundleName),
      path.join(repoRoot, 'OpenBurnBarCore/.build/release', linuxResourceBundleName)
    );
    if (fs.existsSync(daemonBuildRoot)) {
      for (const entry of fs.readdirSync(daemonBuildRoot)) {
        candidates.push(path.join(daemonBuildRoot, entry, 'release', linuxResourceBundleName));
      }
    }
  }
  const found = candidates.find((candidate) => candidate && fs.existsSync(candidate));
  return requireDirectory(found, 'OpenBurnBarCore Linux resource bundle');
}

export function buildLinuxCloudAuthConfig({ env = process.env, requireConfigured = false } = {}) {
  const values = {
    googleOAuthClientID: env.OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID?.trim() ?? '',
    firebaseAPIKey: env.OPENBURNBAR_FIREBASE_API_KEY?.trim() ?? '',
    linuxAppCheckAppID: env.OPENBURNBAR_LINUX_APP_CHECK_APP_ID?.trim() ?? ''
  };
  const present = Object.values(values).filter(Boolean).length;
  if (present !== 0 && present !== Object.keys(values).length) {
    throw new Error('Linux cloud auth configuration must provide all public identifiers together');
  }
  if (present === 0) {
    if (requireConfigured) {
      throw new Error(
        'Release packaging requires OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID, OPENBURNBAR_FIREBASE_API_KEY, and OPENBURNBAR_LINUX_APP_CHECK_APP_ID'
      );
    }
    return { schemaVersion: 1, configured: false };
  }
  if (!/^[A-Za-z0-9._-]{12,512}\.apps\.googleusercontent\.com$/u.test(values.googleOAuthClientID)) {
    throw new Error('OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID is not a valid installed-app client id');
  }
  if (!/^AIza[A-Za-z0-9_-]{20,196}$/u.test(values.firebaseAPIKey)) {
    throw new Error('OPENBURNBAR_FIREBASE_API_KEY is malformed');
  }
  if (!/^1:[0-9]{6,20}:web:[A-Za-z0-9_-]{8,128}$/u.test(values.linuxAppCheckAppID)
      || /placeholder/iu.test(values.linuxAppCheckAppID)) {
    throw new Error('OPENBURNBAR_LINUX_APP_CHECK_APP_ID is malformed or a placeholder');
  }
  return { schemaVersion: 1, configured: true, ...values };
}

function copySqlcipherRuntime(source, destination) {
  const sourceRoot = fs.realpathSync(source);
  const entries = fs.readdirSync(sourceRoot)
    .filter((entry) => entry.startsWith('libsqlcipher.so'))
    .sort();
  if (!entries.some((entry) => entry === 'libsqlcipher.so.0')) {
    throw new Error(`SQLCipher runtime is missing required SONAME libsqlcipher.so.0 in ${source}`);
  }
  fs.mkdirSync(destination, { recursive: true });
  for (const entry of entries) {
    const sourcePath = path.join(sourceRoot, entry);
    const destinationPath = path.join(destination, entry);
    const sourceStat = fs.lstatSync(sourcePath);
    if (!sourceStat.isSymbolicLink()) {
      if (!sourceStat.isFile()) {
        throw new Error(`SQLCipher runtime entry must be a file or symlink: ${sourcePath}`);
      }
      fs.cpSync(sourcePath, destinationPath, { preserveTimestamps: true });
      continue;
    }

    // Homebrew/CI installs can emit absolute SONAME links into the build prefix,
    // and AppImage extraction can rewrite even relative links to an absolute
    // AppDir path. Dereference every in-tree link so no host or AppDir path can
    // leak into the package.
    const targetPath = fs.realpathSync(sourcePath);
    const relativeTarget = path.relative(sourceRoot, targetPath);
    if (!relativeTarget || relativeTarget.startsWith(`..${path.sep}`)
        || relativeTarget === '..' || path.isAbsolute(relativeTarget)) {
      throw new Error(`SQLCipher runtime symlink escapes its runtime directory: ${sourcePath}`);
    }
    if (!fs.statSync(targetPath).isFile()) {
      throw new Error(`SQLCipher runtime symlink target is not a regular file: ${sourcePath}`);
    }
    fs.cpSync(targetPath, destinationPath, { preserveTimestamps: true });
  }
  return entries;
}

function runDaemonStartupProbe(daemon, swiftDir, nativeDir, env) {
  const probeRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-daemon-runtime-probe-'));
  const tokenPath = path.join(probeRoot, 'socket.token');
  const socketPath = path.join(probeRoot, 'daemon.sock');
  const indexPath = path.join(probeRoot, 'index.sqlite');
  const libraryPath = [swiftDir, nativeDir, env.LD_LIBRARY_PATH]
    .filter(Boolean)
    .join(':');
  for (const directory of ['config', 'data', 'run']) {
    fs.mkdirSync(path.join(probeRoot, directory), { recursive: true });
  }
  const probeEnv = {
    ...env,
    HOME: probeRoot,
    XDG_CONFIG_HOME: path.join(probeRoot, 'config'),
    XDG_DATA_HOME: path.join(probeRoot, 'data'),
    XDG_RUNTIME_DIR: path.join(probeRoot, 'run'),
    OPENBURNBAR_DAEMON_SUPPORT_DIR: probeRoot,
    LD_LIBRARY_PATH: libraryPath
  };
  fs.writeFileSync(tokenPath, 'openburnbar-runtime-probe-token\n', { mode: 0o600 });
  try {
    const result = spawnSync(daemon, [
      '--socket-path', socketPath,
      '--index-database-path', indexPath,
      '--socket-auth-token-file', tokenPath
    ], {
      encoding: 'utf8',
      env: probeEnv,
      timeout: 10_000,
      maxBuffer: 8 * 1024 * 1024
    });
    const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`.trim();
    if (result.error?.code !== 'ETIMEDOUT') {
      throw new Error(
        `staged daemon startup probe exited before serving (status ${result.status ?? 'unknown'}):\n${output}`
      );
    }
    if (!fs.existsSync(socketPath)) {
      throw new Error(`staged daemon startup probe timed out without creating its Unix socket:\n${output}`);
    }
    return { startup: output || 'daemon remained alive until probe timeout' };
  } finally {
    fs.rmSync(probeRoot, { recursive: true, force: true });
  }
}

function probeRuntimeBinary(binary, label, swiftDir, nativeDir, env) {
  const libraryPath = [swiftDir, nativeDir, env.LD_LIBRARY_PATH]
    .filter(Boolean)
    .join(':');
  const probeEnv = { ...env, LD_LIBRARY_PATH: libraryPath };
  const ldd = spawnSync('ldd', [binary], {
    encoding: 'utf8',
    env: probeEnv,
    maxBuffer: 8 * 1024 * 1024
  });
  const lddOutput = `${ldd.stdout ?? ''}\n${ldd.stderr ?? ''}`;
  if ((ldd.status ?? 1) !== 0 || /not found/i.test(lddOutput)) {
    throw new Error(`staged ${label} has unresolved shared libraries:\n${lddOutput}`);
  }

  const help = spawnSync(binary, ['--help'], {
    encoding: 'utf8',
    env: probeEnv,
    maxBuffer: 8 * 1024 * 1024
  });
  const helpOutput = `${help.stdout ?? ''}\n${help.stderr ?? ''}`;
  if ((help.status ?? 1) !== 0 || (label === 'daemon' && !helpOutput.includes('socket-path'))) {
    throw new Error(`staged ${label} runtime help probe failed:\n${helpOutput}`);
  }
  return { ldd: lddOutput.trim(), help: helpOutput.trim() };
}

function runRuntimeProbe(daemon, cli, swiftDir, nativeDir, env) {
  const daemonProbe = probeRuntimeBinary(daemon, 'daemon', swiftDir, nativeDir, env);
  const startup = runDaemonStartupProbe(daemon, swiftDir, nativeDir, env);
  const cliProbe = cli ? probeRuntimeBinary(cli, 'CLI', swiftDir, nativeDir, env) : null;
  return {
    ldd: daemonProbe.ldd,
    help: daemonProbe.help,
    ...(cliProbe ? { cliLdd: cliProbe.ldd, cliHelp: cliProbe.help } : {}),
    ...startup
  };
}

export function stageLinuxPackagePayload({
  daemonBinary,
  cliBinary = null,
  playwrightBridge,
  browserRuntimeProbe,
  browserRuntimeRequirements,
  releasePublicKey,
  resourceBundle,
  payloadRoot,
  swiftRuntimeDir,
  sqlcipherLibDir,
  irohNativeLibrary,
  env = process.env,
  probe = true
}) {
  const daemonSource = requireFile(daemonBinary, 'OpenBurnBar daemon');
  const cliSource = cliBinary ? requireFile(cliBinary, 'OpenBurnBar CLI') : null;
  const bridgeSource = requireFile(playwrightBridge, 'Playwright bridge');
  const browserRuntimeProbeSource = requireFile(browserRuntimeProbe, 'browser runtime probe');
  const browserRuntimeRequirementsSource = requireFile(
    browserRuntimeRequirements,
    'browser runtime requirements'
  );
  const releasePublicKeySource = requireRegularFile(releasePublicKey, 'Linux release public key');
  const resourceBundleSource = requireDirectory(resourceBundle, 'OpenBurnBarCore Linux resource bundle');
  const swiftSource = requireDirectory(swiftRuntimeDir, 'Swift runtime');
  const sqlcipherSource = requireDirectory(sqlcipherLibDir, 'SQLCipher runtime');
  const irohNativeSource = requireRegularFile(irohNativeLibrary, 'Linux iroh native runtime');
  const root = path.resolve(payloadRoot);
  const daemonDestination = path.join(root, 'openburnbar-daemon');
  const resourceBundleDestination = path.join(root, linuxResourceBundleName);
  const cliDestination = path.join(root, 'openburnbar-cli');
  const swiftDestination = path.join(root, 'swift');
  const nativeDestination = path.join(root, 'native');
  const playwrightDestination = path.join(root, 'playwright');
  const cloudAuthDestination = path.join(root, 'cloud-auth.json');
  const attestationDestination = path.join(root, 'attestation');

  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(root, { recursive: true });
  fs.copyFileSync(daemonSource, daemonDestination);
  fs.chmodSync(daemonDestination, 0o755);
  fs.cpSync(resourceBundleSource, resourceBundleDestination, {
    recursive: true,
    dereference: false,
    preserveTimestamps: true
  });
  if (cliSource) {
    fs.copyFileSync(cliSource, cliDestination);
    fs.chmodSync(cliDestination, 0o755);
  }
  fs.cpSync(swiftSource, swiftDestination, {
    recursive: true,
    dereference: false,
    preserveTimestamps: true
  });
  const sqlcipherFiles = copySqlcipherRuntime(sqlcipherSource, nativeDestination);
  const irohNativeDestination = path.join(nativeDestination, 'libopenburnbar_iroh.so');
  fs.copyFileSync(irohNativeSource, irohNativeDestination);
  fs.chmodSync(irohNativeDestination, 0o644);
  fs.mkdirSync(playwrightDestination, { recursive: true });
  const bridgeDestination = path.join(
    playwrightDestination,
    'openburnbar-playwright-bridge.js'
  );
  const browserRuntimeProbeDestination = path.join(
    playwrightDestination,
    'openburnbar-browser-runtime-probe'
  );
  const browserRuntimeRequirementsDestination = path.join(
    playwrightDestination,
    'browser-runtime-requirements.json'
  );
  fs.copyFileSync(bridgeSource, bridgeDestination);
  fs.chmodSync(bridgeDestination, 0o644);
  fs.copyFileSync(browserRuntimeProbeSource, browserRuntimeProbeDestination);
  fs.chmodSync(browserRuntimeProbeDestination, 0o755);
  fs.copyFileSync(browserRuntimeRequirementsSource, browserRuntimeRequirementsDestination);
  fs.chmodSync(browserRuntimeRequirementsDestination, 0o644);
  const cloudAuth = buildLinuxCloudAuthConfig({
    env,
    requireConfigured: env.OPENBURNBAR_LINUX_RELEASE_BUILD === '1'
  });
  fs.writeFileSync(cloudAuthDestination, `${JSON.stringify(cloudAuth, null, 2)}\n`, {
    encoding: 'utf8',
    mode: 0o644
  });
  fs.chmodSync(cloudAuthDestination, 0o644);
  fs.mkdirSync(attestationDestination, { recursive: true });
  const releasePublicKeyDestination = path.join(attestationDestination, 'release-ed25519.pub.pem');
  const installedManifestDestination = path.join(attestationDestination, 'installed-manifest.json');
  const installedManifestSignatureDestination = `${installedManifestDestination}.sig`;
  fs.copyFileSync(releasePublicKeySource, releasePublicKeyDestination);
  fs.writeFileSync(installedManifestDestination, '{}\n', { mode: 0o644 });
  fs.writeFileSync(installedManifestSignatureDestination, Buffer.alloc(64), { mode: 0o644 });
  for (const file of [
    releasePublicKeyDestination,
    installedManifestDestination,
    installedManifestSignatureDestination
  ]) fs.chmodSync(file, 0o644);
  const runtimeProbe = probe
    ? runRuntimeProbe(
      daemonDestination,
      cliSource ? cliDestination : null,
      swiftDestination,
      nativeDestination,
      env
    )
    : null;

  return {
    schemaVersion: 1,
    architecture: process.arch === 'arm64' ? 'aarch64' : process.arch === 'x64' ? 'x86_64' : process.arch,
    daemon: daemonDestination,
    resourceBundle: resourceBundleDestination,
    cli: cliSource ? cliDestination : null,
    swiftRuntime: swiftDestination,
    nativeRuntime: nativeDestination,
    irohNativeLibrary: irohNativeDestination,
    playwrightRuntime: playwrightDestination,
    playwrightBridge: bridgeDestination,
    browserRuntimeProbe: browserRuntimeProbeDestination,
    browserRuntimeRequirements: browserRuntimeRequirementsDestination,
    cloudAuthConfig: cloudAuthDestination,
    cloudAuthConfigured: cloudAuth.configured,
    releasePublicKey: releasePublicKeyDestination,
    installedManifest: installedManifestDestination,
    installedManifestSignature: installedManifestSignatureDestination,
    sqlcipherFiles,
    runtimeProbe
  };
}
