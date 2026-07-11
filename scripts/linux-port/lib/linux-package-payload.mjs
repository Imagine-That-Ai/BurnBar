import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
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

function copySqlcipherRuntime(source, destination) {
  const entries = fs.readdirSync(source)
    .filter((entry) => entry.startsWith('libsqlcipher.so'))
    .sort();
  if (!entries.some((entry) => entry === 'libsqlcipher.so.0')) {
    throw new Error(`SQLCipher runtime is missing required SONAME libsqlcipher.so.0 in ${source}`);
  }
  fs.mkdirSync(destination, { recursive: true });
  for (const entry of entries) {
    fs.cpSync(path.join(source, entry), path.join(destination, entry), {
      dereference: false,
      preserveTimestamps: true
    });
  }
  return entries;
}

function runRuntimeProbe(daemon, swiftDir, nativeDir, env) {
  const libraryPath = [swiftDir, nativeDir, env.LD_LIBRARY_PATH]
    .filter(Boolean)
    .join(':');
  const probeEnv = { ...env, LD_LIBRARY_PATH: libraryPath };
  const ldd = spawnSync('ldd', [daemon], {
    encoding: 'utf8',
    env: probeEnv,
    maxBuffer: 8 * 1024 * 1024
  });
  const lddOutput = `${ldd.stdout ?? ''}\n${ldd.stderr ?? ''}`;
  if ((ldd.status ?? 1) !== 0 || /not found/i.test(lddOutput)) {
    throw new Error(`staged daemon has unresolved shared libraries:\n${lddOutput}`);
  }

  const help = spawnSync(daemon, ['--help'], {
    encoding: 'utf8',
    env: probeEnv,
    maxBuffer: 8 * 1024 * 1024
  });
  const helpOutput = `${help.stdout ?? ''}\n${help.stderr ?? ''}`;
  if ((help.status ?? 1) !== 0 || !helpOutput.includes('socket-path')) {
    throw new Error(`staged daemon runtime probe failed:\n${helpOutput}`);
  }
  return {
    ldd: lddOutput.trim(),
    help: helpOutput.trim()
  };
}

export function stageLinuxPackagePayload({
  daemonBinary,
  playwrightBridge,
  browserRuntimeProbe,
  browserRuntimeRequirements,
  payloadRoot,
  swiftRuntimeDir,
  sqlcipherLibDir,
  env = process.env,
  probe = true
}) {
  const daemonSource = requireFile(daemonBinary, 'OpenBurnBar daemon');
  const bridgeSource = requireFile(playwrightBridge, 'Playwright bridge');
  const browserRuntimeProbeSource = requireFile(browserRuntimeProbe, 'browser runtime probe');
  const browserRuntimeRequirementsSource = requireFile(
    browserRuntimeRequirements,
    'browser runtime requirements'
  );
  const swiftSource = requireDirectory(swiftRuntimeDir, 'Swift runtime');
  const sqlcipherSource = requireDirectory(sqlcipherLibDir, 'SQLCipher runtime');
  const root = path.resolve(payloadRoot);
  const daemonDestination = path.join(root, 'openburnbar-daemon');
  const swiftDestination = path.join(root, 'swift');
  const nativeDestination = path.join(root, 'native');
  const playwrightDestination = path.join(root, 'playwright');

  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(root, { recursive: true });
  fs.copyFileSync(daemonSource, daemonDestination);
  fs.chmodSync(daemonDestination, 0o755);
  fs.cpSync(swiftSource, swiftDestination, {
    recursive: true,
    dereference: false,
    preserveTimestamps: true
  });
  const sqlcipherFiles = copySqlcipherRuntime(sqlcipherSource, nativeDestination);
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
  const runtimeProbe = probe
    ? runRuntimeProbe(daemonDestination, swiftDestination, nativeDestination, env)
    : null;

  return {
    schemaVersion: 1,
    architecture: process.arch === 'arm64' ? 'aarch64' : process.arch === 'x64' ? 'x86_64' : process.arch,
    daemon: daemonDestination,
    swiftRuntime: swiftDestination,
    nativeRuntime: nativeDestination,
    playwrightRuntime: playwrightDestination,
    playwrightBridge: bridgeDestination,
    browserRuntimeProbe: browserRuntimeProbeDestination,
    browserRuntimeRequirements: browserRuntimeRequirementsDestination,
    sqlcipherFiles,
    runtimeProbe
  };
}
