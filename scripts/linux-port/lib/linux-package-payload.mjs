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

export function swiftTargetInfo(command = 'swift', env = process.env) {
  const result = spawnSync(command, ['-print-target-info'], {
    encoding: 'utf8',
    env: { ...process.env, ...env },
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
  const override = env.OPENBURNBAR_SWIFT_LIB_DIR?.trim();
  if (override) {
    // An explicit runtime is authoritative. Avoid probing Swift (which may
    // be unavailable on a packaging host) and fail directly for bad paths.
    return requireDirectory(override, 'Swift runtime');
  }
  const candidates = [];
  const info = targetInfo ?? swiftTargetInfo('swift', env);
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

const legacyLinuxResourceBundleName = 'OpenBurnBarCore_OpenBurnBarCore.resources';
const linuxResourceBundlePattern = /^OpenBurnBarCore_.+\.resources$/u;
export const linuxResourceBundlesDirectoryName = 'resource-bundles';

function resourceBundlesIn(directory) {
  if (!directory || !fs.existsSync(directory) || !fs.statSync(directory).isDirectory()) return [];
  return fs.readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && linuxResourceBundlePattern.test(entry.name))
    .map((entry) => path.resolve(directory, entry.name))
    .sort((left, right) => path.basename(left).localeCompare(path.basename(right)));
}

function resourceBundleBuildDirectories(repoRoot) {
  const daemonBuildRoot = path.join(repoRoot, 'OpenBurnBarDaemon/.build');
  const candidates = [
    path.join(daemonBuildRoot, 'release'),
    path.join(daemonBuildRoot, 'aarch64-unknown-linux-gnu/release'),
    path.join(daemonBuildRoot, 'x86_64-unknown-linux-gnu/release'),
    path.join(repoRoot, 'OpenBurnBarCore/.build/release')
  ];
  if (fs.existsSync(daemonBuildRoot)) {
    for (const entry of fs.readdirSync(daemonBuildRoot)) {
      candidates.push(path.join(daemonBuildRoot, entry, 'release'));
    }
  }
  return [...new Set(candidates.map((candidate) => path.resolve(candidate)))];
}

export function resolveLinuxResourceBundles({ repoRoot, env = process.env } = {}) {
  const override = env.OPENBURNBAR_LINUX_RESOURCE_BUNDLE?.trim();
  if (override) {
    const explicit = requireDirectory(override, 'OpenBurnBarCore Linux resource bundle');
    const siblings = resourceBundlesIn(path.dirname(explicit));
    return siblings.includes(explicit) ? siblings : [explicit];
  }
  if (repoRoot) {
    for (const directory of resourceBundleBuildDirectories(repoRoot)) {
      const bundles = resourceBundlesIn(directory);
      if (bundles.length > 0) return bundles;
    }
  }
  throw new Error('OpenBurnBarCore Linux resource bundle directory not found: (unset)');
}

export function resolveLinuxResourceBundle({ repoRoot, env = process.env } = {}) {
  const bundles = resolveLinuxResourceBundles({ repoRoot, env });
  return bundles.find((bundle) => path.basename(bundle) === legacyLinuxResourceBundleName)
    ?? bundles[0];
}

function requireResourceBundles(resourceBundles, resourceBundle) {
  const candidates = resourceBundles ?? (resourceBundle ? [resourceBundle] : []);
  if (!Array.isArray(candidates) || candidates.length === 0) {
    throw new Error('At least one OpenBurnBarCore Linux resource bundle is required');
  }
  const byName = new Map();
  for (const candidate of candidates) {
    const source = requireDirectory(candidate, 'OpenBurnBarCore Linux resource bundle');
    const name = path.basename(source);
    if (!linuxResourceBundlePattern.test(name)) {
      throw new Error(`OpenBurnBarCore Linux resource bundle has an invalid basename: ${name}`);
    }
    const existing = byName.get(name);
    if (existing && existing !== source) {
      throw new Error(`Duplicate OpenBurnBarCore Linux resource bundle basename: ${name}`);
    }
    byName.set(name, source);
  }
  return [...byName.values()].sort((left, right) => path.basename(left).localeCompare(path.basename(right)));
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

function payloadRegularFile(root, relativePath, label, mode = null) {
  const candidate = requireRegularFile(path.join(root, relativePath), label);
  if (mode !== null && (fs.statSync(candidate).mode & 0o777) !== mode) {
    throw new Error(`${label} mode must be ${mode.toString(8)}: ${candidate}`);
  }
  return candidate;
}

/**
 * Validate a payload that was assembled by another native build host.
 *
 * This is intentionally read-only. The normal staging path owns and replaces
 * its destination, while this path is for Swift-less packaging hosts that
 * receive an architecture-matched payload from a separate builder.
 */
export function validateLinuxPackagePayload({
  payloadRoot,
  env = process.env,
  probe = true
}) {
  const root = requireDirectory(payloadRoot, 'Linux package payload');
  const daemon = payloadRegularFile(root, 'openburnbar-daemon', 'OpenBurnBar daemon', 0o755);
  const cli = payloadRegularFile(root, 'openburnbar-cli', 'OpenBurnBar CLI', 0o755);
  // Accept legacy payloads that staged the single bundle at the payload root,
  // while new payloads keep all bundles in one directory that package tools
  // can install into /usr/bin without hardcoding SwiftPM target names.
  const resourceBundleRoot = path.join(root, linuxResourceBundlesDirectoryName);
  const resourceBundles = requireResourceBundles(
    resourceBundlesIn(fs.existsSync(resourceBundleRoot) ? resourceBundleRoot : root)
  );
  const resourceBundle = resourceBundles.find(
    (bundle) => path.basename(bundle) === legacyLinuxResourceBundleName
  ) ?? resourceBundles[0];
  const swiftRuntime = requireDirectory(path.join(root, 'swift'), 'Swift runtime');
  const nativeRuntime = requireDirectory(path.join(root, 'native'), 'Linux native runtime');
  payloadRegularFile(
    root,
    'native/libsqlcipher.so.0',
    'SQLCipher runtime SONAME'
  );
  const sqlcipherFiles = fs.readdirSync(nativeRuntime)
    .filter((entry) => entry.startsWith('libsqlcipher.so'))
    .sort();
  for (const entry of sqlcipherFiles) {
    payloadRegularFile(root, `native/${entry}`, `SQLCipher runtime ${entry}`);
  }
  const irohNativeLibrary = payloadRegularFile(
    root,
    'native/libopenburnbar_iroh.so',
    'Linux iroh native runtime',
    0o644
  );
  const playwrightRuntime = requireDirectory(path.join(root, 'playwright'), 'Playwright runtime');
  const playwrightBridge = payloadRegularFile(
    root,
    'playwright/openburnbar-playwright-bridge.js',
    'Playwright bridge',
    0o644
  );
  const browserRuntimeProbe = payloadRegularFile(
    root,
    'playwright/openburnbar-browser-runtime-probe',
    'browser runtime probe',
    0o755
  );
  const browserRuntimeRequirements = payloadRegularFile(
    root,
    'playwright/browser-runtime-requirements.json',
    'browser runtime requirements',
    0o644
  );
  const cloudAuthConfig = payloadRegularFile(root, 'cloud-auth.json', 'cloud auth config', 0o644);
  let cloudAuth;
  try {
    cloudAuth = JSON.parse(fs.readFileSync(cloudAuthConfig, 'utf8'));
  } catch (error) {
    throw new Error(`cloud auth config is invalid JSON: ${error.message}`);
  }
  const attestation = path.join(root, 'attestation');
  requireDirectory(attestation, 'Linux release attestation');
  const releasePublicKey = payloadRegularFile(
    root,
    'attestation/release-ed25519.pub.pem',
    'Linux release public key',
    0o644
  );
  const installedManifest = payloadRegularFile(
    root,
    'attestation/installed-manifest.json',
    'installed manifest',
    0o644
  );
  const installedManifestSignature = payloadRegularFile(
    root,
    'attestation/installed-manifest.json.sig',
    'installed manifest signature',
    0o644
  );
  if (fs.statSync(installedManifestSignature).size !== 64) {
    throw new Error(`installed manifest signature must be exactly 64 bytes: ${installedManifestSignature}`);
  }

  const runtimeProbe = probe
    ? runRuntimeProbe(daemon, cli, swiftRuntime, nativeRuntime, env)
    : null;

  return {
    schemaVersion: 1,
    architecture: process.arch === 'arm64' ? 'aarch64' : process.arch === 'x64' ? 'x86_64' : process.arch,
    staged: true,
    payloadRoot: root,
    daemon,
    resourceBundle,
    resourceBundles,
    cli,
    swiftRuntime,
    nativeRuntime,
    irohNativeLibrary,
    playwrightRuntime,
    playwrightBridge,
    browserRuntimeProbe,
    browserRuntimeRequirements,
    cloudAuthConfig,
    cloudAuthConfigured: cloudAuth.configured === true,
    releasePublicKey,
    installedManifest,
    installedManifestSignature,
    sqlcipherFiles,
    runtimeProbe
  };
}

export function stageLinuxPackagePayload({
  daemonBinary,
  cliBinary = null,
  playwrightBridge,
  browserRuntimeProbe,
  browserRuntimeRequirements,
  releasePublicKey,
  resourceBundle = null,
  resourceBundles = null,
  payloadRoot,
  swiftRuntimeDir,
  sqlcipherLibDir,
  irohNativeLibrary,
  textExpansionManifest = null,
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
  const resourceBundleSources = requireResourceBundles(resourceBundles, resourceBundle);
  const swiftSource = requireDirectory(swiftRuntimeDir, 'Swift runtime');
  const sqlcipherSource = requireDirectory(sqlcipherLibDir, 'SQLCipher runtime');
  const irohNativeSource = requireRegularFile(irohNativeLibrary, 'Linux iroh native runtime');
  const textExpansionManifestSource = textExpansionManifest
    ? requireRegularFile(textExpansionManifest, 'signed text-expansion manifest')
    : null;
  const root = path.resolve(payloadRoot);
  const resourceBundlesDestination = path.join(root, linuxResourceBundlesDirectoryName);
  const daemonDestination = path.join(root, 'openburnbar-daemon');
  const cliDestination = path.join(root, 'openburnbar-cli');
  const swiftDestination = path.join(root, 'swift');
  const nativeDestination = path.join(root, 'native');
  const playwrightDestination = path.join(root, 'playwright');
  const cloudAuthDestination = path.join(root, 'cloud-auth.json');
  const attestationDestination = path.join(root, 'attestation');
  const textExpansionManifestDestination = path.join(root, 'text-expansion-engine.json');

  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(root, { recursive: true });
  fs.copyFileSync(daemonSource, daemonDestination);
  fs.chmodSync(daemonDestination, 0o755);
  const resourceBundleDestinations = resourceBundleSources.map((source) => {
    const destination = path.join(resourceBundlesDestination, path.basename(source));
    fs.cpSync(source, destination, {
      recursive: true,
      dereference: false,
      preserveTimestamps: true
    });
    return destination;
  });
  const resourceBundleDestination = resourceBundleDestinations.find(
    (bundle) => path.basename(bundle) === legacyLinuxResourceBundleName
  ) ?? resourceBundleDestinations[0];
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
  if (textExpansionManifestSource) {
    fs.copyFileSync(textExpansionManifestSource, textExpansionManifestDestination);
    fs.chmodSync(textExpansionManifestDestination, 0o644);
  }
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
    resourceBundles: resourceBundleDestinations,
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
    textExpansionManifest: textExpansionManifestSource ? textExpansionManifestDestination : null,
    sqlcipherFiles,
    runtimeProbe
  };
}
