import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export const INSTALLED_RELEASE_MANIFEST_NAME = 'installed-manifest.json';
export const INSTALLED_RELEASE_MANIFEST_SIGNATURE_NAME = 'installed-manifest.json.sig';
export const LINUX_ATTESTATION_POLICY_ID = 'openburnbar-linux-tpm2-ima-v1';

const SHARED_SYSTEM_DIRECTORIES = new Set([
  '/usr',
  '/usr/bin',
  '/usr/lib',
  '/usr/lib/systemd',
  '/usr/lib/systemd/system',
  '/usr/lib/systemd/user',
  '/usr/libexec',
  '/usr/share',
  '/usr/share/applications',
  '/usr/share/doc',
  '/usr/share/icons',
  '/usr/share/icons/hicolor',
  '/usr/share/icons/hicolor/256x256',
  '/usr/share/icons/hicolor/256x256/apps'
]);

function requireRegularFile(candidate, label) {
  if (!candidate || !fs.existsSync(candidate)) {
    throw new Error(`${label} not found: ${candidate || '(unset)'}`);
  }
  const stat = fs.lstatSync(candidate);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`${label} must be a regular file: ${candidate}`);
  }
  return path.resolve(candidate);
}

function requireDirectory(candidate, label) {
  if (!candidate || !fs.existsSync(candidate)) {
    throw new Error(`${label} not found: ${candidate || '(unset)'}`);
  }
  const stat = fs.lstatSync(candidate);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error(`${label} must be a directory: ${candidate}`);
  }
  return path.resolve(candidate);
}

function normalizedMode(stat) {
  return (stat.mode & 0o7777).toString(8).padStart(4, '0');
}

function sha256Buffer(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function sha256File(file) {
  return sha256Buffer(fs.readFileSync(file));
}

function compareUtf8(left, right) {
  return Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonicalize(value[key])])
    );
  }
  return value;
}

export function canonicalJSON(value) {
  return `${JSON.stringify(canonicalize(value))}\n`;
}

function copyFile(source, root, destination, mode) {
  const resolved = requireRegularFile(source, destination);
  const target = path.join(root, destination.slice(1));
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(resolved, target);
  fs.chmodSync(target, mode);
}

function copyTree(source, root, destination) {
  const resolved = requireDirectory(source, destination);
  const target = path.join(root, destination.slice(1));
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.cpSync(resolved, target, {
    recursive: true,
    dereference: false,
    preserveTimestamps: false
  });
}

function walk(root, current = root, result = []) {
  for (const entry of fs.readdirSync(current, { withFileTypes: true }).sort((a, b) =>
    compareUtf8(a.name, b.name))) {
    const full = path.join(current, entry.name);
    if (entry.isSymbolicLink()) {
      const relative = `/${path.relative(root, full)}`;
      const target = fs.readlinkSync(full);
      const resolved = path.resolve(path.dirname(full), target);
      if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
        throw new Error(`package payload symlink escapes root: ${relative} -> ${target}`);
      }
      result.push(full);
    } else if (entry.isDirectory()) {
      walk(root, full, result);
    } else if (entry.isFile()) {
      result.push(full);
    } else {
      throw new Error(`package payload contains unsupported item: ${full}`);
    }
  }
  return result;
}

function installedFileRecords(root, excludedPaths = new Set()) {
  return walk(root)
    .map((file) => {
      const installedPath = `/${path.relative(root, file)}`;
      if (excludedPaths.has(installedPath)) return null;
      const stat = fs.lstatSync(file);
      if (stat.isSymbolicLink()) {
        return {
          path: installedPath,
          type: 'symlink',
          target: fs.readlinkSync(file),
          mode: normalizedMode(stat),
          uid: 0,
          gid: 0
        };
      }
      return {
        path: installedPath,
        type: 'file',
        sha256: sha256File(file),
        size: stat.size,
        mode: normalizedMode(stat),
        uid: 0,
        gid: 0
      };
    })
    .filter(Boolean)
    .sort((a, b) => compareUtf8(a.path, b.path));
}

function filesRoot(files) {
  const lines = files.map((file) => file.type === 'file'
    ? `${file.path}\0file\0${file.sha256}\0${file.size}\0${file.mode}\0${file.uid}\0${file.gid}`
    : `${file.path}\0symlink\0${file.target}\0${file.mode}\0${file.uid}\0${file.gid}`)
    .sort(compareUtf8);
  return sha256Buffer(Buffer.from(lines.join('\n'), 'utf8'));
}

export function createInstalledReleaseManifest({
  root,
  version,
  gitCommit,
  architecture,
  packageType,
  packageName = 'open-burn-bar',
  policyId = LINUX_ATTESTATION_POLICY_ID
}) {
  if (!/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/.test(version)) {
    throw new Error(`invalid package version: ${version}`);
  }
  if (!/^[a-f0-9]{40}$/.test(gitCommit)) throw new Error('gitCommit must be lowercase 40-character hex');
  if (!['aarch64', 'x86_64'].includes(architecture)) throw new Error(`unsupported architecture: ${architecture}`);
  if (!['deb', 'rpm'].includes(packageType)) throw new Error(`unsupported package type: ${packageType}`);

  const installedPath = `/usr/share/openburnbar/attestation/${INSTALLED_RELEASE_MANIFEST_NAME}`;
  const signaturePath = `/usr/share/openburnbar/attestation/${INSTALLED_RELEASE_MANIFEST_SIGNATURE_NAME}`;
  const files = installedFileRecords(root, new Set([installedPath, signaturePath]));
  const daemon = files.find((file) => file.path === '/usr/bin/openburnbar-daemon' && file.type === 'file');
  if (!daemon) throw new Error('installed manifest requires /usr/bin/openburnbar-daemon');
  const manifest = {
    schemaVersion: 1,
    product: 'OpenBurnBar',
    appId: 'dev.openburnbar.OpenBurnBar',
    packageVersion: version,
    gitCommit,
    packageArchitecture: architecture,
    packageFormat: packageType,
    packageName,
    policyId,
    brokerProtocolVersion: 1,
    installedFilesRootSha256: filesRoot(files),
    authorizedClients: [{
      role: 'daemon',
      path: daemon.path,
      sha256: daemon.sha256,
      ownerUid: 0,
      ownerGid: 0,
      mode: 0o755
    }],
    files
  };
  const bytes = Buffer.from(canonicalJSON(manifest), 'utf8');
  const destination = path.join(root, installedPath.slice(1));
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, bytes, { mode: 0o644 });
  return {
    manifest,
    path: destination,
    releaseDigestSha256: sha256Buffer(bytes)
  };
}

export function signInstalledReleaseManifest({ manifestPath, signaturePath, privateKeyPem, publicKeyPath }) {
  let privateKey;
  let publicKey;
  try {
    privateKey = crypto.createPrivateKey(privateKeyPem);
    publicKey = crypto.createPublicKey(
      fs.readFileSync(requireRegularFile(publicKeyPath, 'attestation release public key'))
    );
  } catch (error) {
    throw new Error(`invalid installed-manifest signing key: ${error.message}`);
  }
  if (privateKey.asymmetricKeyType !== 'ed25519' || publicKey.asymmetricKeyType !== 'ed25519') {
    throw new Error('installed-manifest signing keys must be Ed25519');
  }
  const derivedPublic = crypto.createPublicKey(privateKey).export({ type: 'spki', format: 'der' });
  const expectedPublic = publicKey.export({ type: 'spki', format: 'der' });
  if (!crypto.timingSafeEqual(derivedPublic, expectedPublic)) {
    throw new Error('installed-manifest private key does not match packaged public key');
  }
  const signature = crypto.sign(null, fs.readFileSync(manifestPath), privateKey);
  if (signature.length !== 64 || !crypto.verify(null, fs.readFileSync(manifestPath), publicKey, signature)) {
    throw new Error('installed-manifest signature self-verification failed');
  }
  fs.writeFileSync(signaturePath, signature, { mode: 0o644 });
  return signaturePath;
}

export function stageNativeLinuxPackageRoot({
  root,
  guiBinary,
  daemonBinary,
  attestdBinary,
  swiftRuntimeDir,
  nativeRuntimeDir,
  assets,
  version,
  gitCommit,
  architecture,
  packageType,
  privateKeyPem
}) {
  const destinationRoot = path.resolve(root);
  fs.rmSync(destinationRoot, { recursive: true, force: true });
  fs.mkdirSync(destinationRoot, { recursive: true });

  copyFile(guiBinary, destinationRoot, '/usr/bin/openburnbar-linux-desktop', 0o755);
  copyFile(daemonBinary, destinationRoot, '/usr/bin/openburnbar-daemon', 0o755);
  copyFile(attestdBinary, destinationRoot, '/usr/libexec/openburnbar-attestd', 0o755);
  copyTree(swiftRuntimeDir, destinationRoot, '/usr/lib/openburnbar/swift');
  copyTree(nativeRuntimeDir, destinationRoot, '/usr/lib/openburnbar/native');

  const requiredAssets = {
    daemonLaunch: ['/usr/libexec/openburnbar-daemon-launch', 0o755],
    daemonUserService: ['/usr/lib/systemd/user/openburnbar-daemon.service', 0o644],
    attestdService: ['/usr/lib/systemd/system/openburnbar-attestd.service', 0o644],
    attestdSocket: ['/usr/lib/systemd/system/openburnbar-attestd.socket', 0o644],
    attestdPurgeHelper: ['/usr/libexec/openburnbar-attestd-purge-state', 0o755],
    attestdActivationReady: ['/usr/libexec/openburnbar-attestd-activation-ready', 0o755],
    restartActiveUserDaemons: ['/usr/libexec/openburnbar-restart-active-user-daemons', 0o755],
    desktopEntry: ['/usr/share/applications/dev.openburnbar.OpenBurnBar.desktop', 0o644],
    safeModeDesktopEntry: ['/usr/share/applications/dev.openburnbar.OpenBurnBar.SafeMode.desktop', 0o644],
    autostartEntry: ['/usr/share/openburnbar/autostart/openburnbar.desktop', 0o644],
    daemonEnvExample: ['/usr/share/doc/openburnbar/daemon.env.example', 0o644],
    customXdgDropInExample: ['/usr/share/doc/openburnbar/systemd/custom-xdg.conf.example', 0o644],
    attestationSchema: ['/usr/share/openburnbar/attestation/installed-manifest.schema.json', 0o644],
    attestationPublicKey: ['/usr/share/openburnbar/attestation/release-ed25519.pub.pem', 0o644],
    icon: ['/usr/share/icons/hicolor/256x256/apps/dev.openburnbar.OpenBurnBar.png', 0o644]
  };
  for (const [key, [destination, mode]] of Object.entries(requiredAssets)) {
    copyFile(assets[key], destinationRoot, destination, mode);
  }

  const release = createInstalledReleaseManifest({
    root: destinationRoot,
    version,
    gitCommit,
    architecture,
    packageType
  });
  const signaturePath = path.join(
    destinationRoot,
    `usr/share/openburnbar/attestation/${INSTALLED_RELEASE_MANIFEST_SIGNATURE_NAME}`
  );
  signInstalledReleaseManifest({
    manifestPath: release.path,
    signaturePath,
    privateKeyPem,
    publicKeyPath: path.join(destinationRoot, 'usr/share/openburnbar/attestation/release-ed25519.pub.pem')
  });
  return { root: destinationRoot, ...release, signaturePath };
}

export function rpmOwnedPaths(root) {
  const directories = new Set();
  const files = [];
  for (const item of walk(root)) {
    const installedPath = `/${path.relative(root, item)}`;
    files.push(installedPath.replaceAll('%', '%%'));
    let parent = path.posix.dirname(installedPath);
    while (parent !== '/' && !SHARED_SYSTEM_DIRECTORIES.has(parent)) {
      directories.add(parent);
      parent = path.posix.dirname(parent);
    }
  }
  return [
    ...[...directories].sort(compareUtf8).map((directory) => `%dir ${directory.replaceAll('%', '%%')}`),
    ...files.sort(compareUtf8)
  ];
}

function runChecked(command, args, options = {}) {
  const environment = { ...(options.env ?? process.env) };
  delete environment.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM;
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: environment,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024
  });
  if ((result.status ?? 1) !== 0) {
    throw new Error([
      `command failed: ${[command, ...args].join(' ')}`,
      result.stdout ?? '',
      result.stderr ?? ''
    ].filter(Boolean).join('\n'));
  }
  return result;
}

function runBinaryChecked(command, args, options = {}) {
  const environment = { ...(options.env ?? process.env) };
  delete environment.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM;
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: environment,
    input: options.input,
    encoding: null,
    maxBuffer: 1024 * 1024 * 1024
  });
  if ((result.status ?? 1) !== 0) {
    throw new Error([
      `command failed: ${[command, ...args].join(' ')}`,
      result.stdout?.toString('utf8') ?? '',
      result.stderr?.toString('utf8') ?? ''
    ].filter(Boolean).join('\n'));
  }
  return result;
}

function extractRpmPayload(rpm, destination, runner = runBinaryChecked) {
  fs.rmSync(destination, { recursive: true, force: true });
  fs.mkdirSync(destination, { recursive: true });
  const archive = runner('rpm2cpio', [rpm]);
  if (!Buffer.isBuffer(archive.stdout)) {
    throw new Error('rpm2cpio did not return a binary RPM payload');
  }
  runner('cpio', ['-idm', '--quiet', '--no-absolute-filenames'], {
    cwd: destination,
    input: archive.stdout
  });
  return destination;
}

function verifyExtractedRpmPayload({ sourceRoot, extractedRoot }) {
  const manifestRelative = `usr/share/openburnbar/attestation/${INSTALLED_RELEASE_MANIFEST_NAME}`;
  const signatureRelative = `usr/share/openburnbar/attestation/${INSTALLED_RELEASE_MANIFEST_SIGNATURE_NAME}`;
  const publicKeyRelative = 'usr/share/openburnbar/attestation/release-ed25519.pub.pem';
  const sourceManifest = fs.readFileSync(requireRegularFile(
    path.join(sourceRoot, manifestRelative),
    'source installed manifest'
  ));
  const extractedManifestPath = requireRegularFile(
    path.join(extractedRoot, manifestRelative),
    'RPM installed manifest'
  );
  const extractedManifest = fs.readFileSync(extractedManifestPath);
  const sourceSignature = fs.readFileSync(requireRegularFile(
    path.join(sourceRoot, signatureRelative),
    'source installed manifest signature'
  ));
  const extractedSignature = fs.readFileSync(requireRegularFile(
    path.join(extractedRoot, signatureRelative),
    'RPM installed manifest signature'
  ));
  const sourcePublicKey = fs.readFileSync(requireRegularFile(
    path.join(sourceRoot, publicKeyRelative),
    'source attestation release public key'
  ));
  const extractedPublicKey = fs.readFileSync(requireRegularFile(
    path.join(extractedRoot, publicKeyRelative),
    'RPM attestation release public key'
  ));
  if (!sourceManifest.equals(extractedManifest)
      || !sourceSignature.equals(extractedSignature)
      || !sourcePublicKey.equals(extractedPublicKey)) {
    throw new Error('RPM changed the signed installed-manifest trust material');
  }

  let manifest;
  let publicKey;
  try {
    manifest = JSON.parse(extractedManifest.toString('utf8'));
    publicKey = crypto.createPublicKey(extractedPublicKey);
  } catch (error) {
    throw new Error(`RPM installed-manifest trust material is invalid: ${error.message}`);
  }
  if (manifest.packageFormat !== 'rpm'
      || extractedSignature.length !== 64
      || !crypto.verify(null, extractedManifest, publicKey, extractedSignature)) {
    throw new Error('RPM installed-manifest signature or package binding is invalid');
  }

  const excluded = new Set([`/${manifestRelative}`, `/${signatureRelative}`]);
  const actualFiles = installedFileRecords(extractedRoot, excluded);
  if (canonicalJSON(actualFiles) !== canonicalJSON(manifest.files)) {
    const expectedByPath = new Map(manifest.files.map((file) => [file.path, file]));
    const actualByPath = new Map(actualFiles.map((file) => [file.path, file]));
    const paths = [...new Set([...expectedByPath.keys(), ...actualByPath.keys()])]
      .sort(compareUtf8);
    const changed = paths.find((filePath) =>
      canonicalJSON(expectedByPath.get(filePath) ?? null)
        !== canonicalJSON(actualByPath.get(filePath) ?? null));
    throw new Error([
      'RPM payload files do not exactly match the signed installed manifest',
      changed ? `first mismatch: ${changed}` : '',
      changed ? `expected: ${JSON.stringify(expectedByPath.get(changed) ?? null)}` : '',
      changed ? `actual: ${JSON.stringify(actualByPath.get(changed) ?? null)}` : ''
    ].filter(Boolean).join('; '));
  }
  const actualRoot = filesRoot(actualFiles);
  if (actualRoot !== manifest.installedFilesRootSha256) {
    throw new Error('RPM payload root does not match the signed installed manifest');
  }
  const daemon = actualFiles.find((file) =>
    file.type === 'file' && file.path === '/usr/bin/openburnbar-daemon');
  const authorized = manifest.authorizedClients?.find((client) => client.role === 'daemon');
  if (!daemon || !authorized
      || authorized.path !== daemon.path
      || authorized.sha256 !== daemon.sha256
      || authorized.ownerUid !== daemon.uid
      || authorized.ownerGid !== daemon.gid
      || authorized.mode.toString(8).padStart(4, '0') !== daemon.mode) {
    throw new Error('RPM daemon payload does not match the signed authorized client');
  }
  return { manifest, actualFiles, actualRoot };
}

function installedSizeKiB(root) {
  return Math.ceil(walk(root).reduce((total, file) => {
    const stat = fs.lstatSync(file);
    return total + (stat.isFile() ? stat.size : Buffer.byteLength(fs.readlinkSync(file)));
  }, 0) / 1024);
}

function normalizedScriptBody(file) {
  const source = fs.readFileSync(requireRegularFile(file, 'package lifecycle script'), 'utf8');
  return source.replace(/^#![^\n]*\n/u, '').trimEnd();
}

export function buildDebPackage({
  root,
  output,
  version,
  architecture,
  scripts,
  runner = runChecked
}) {
  const debArchitecture = architecture === 'aarch64' ? 'arm64' : architecture === 'x86_64' ? 'amd64' : null;
  if (!debArchitecture) throw new Error(`unsupported Debian architecture: ${architecture}`);
  const controlDirectory = path.join(root, 'DEBIAN');
  fs.mkdirSync(controlDirectory, { recursive: true });
  const control = [
    'Package: open-burn-bar',
    `Version: ${version}`,
    `Architecture: ${debArchitecture}`,
    `Installed-Size: ${installedSizeKiB(root)}`,
    'Maintainer: OpenBurnBar Release Engineering <release@openburnbar.dev>',
    'Priority: optional',
    'Section: utils',
    'Depends: libayatana-appindicator3-1, libwebkit2gtk-4.1-0, libgtk-3-0, libsecret-tools',
    'Recommends: gnome-keyring | libkf5wallet-bin | libkf6wallet-bin',
    'Description: Local-first AI agent cost and control dashboard',
    ' OpenBurnBar desktop, local daemon, and fail-closed Linux attestation broker.',
    ''
  ].join('\n');
  fs.writeFileSync(path.join(controlDirectory, 'control'), control, { mode: 0o644 });
  for (const name of ['preinst', 'postinst', 'prerm', 'postrm']) {
    if (!scripts[name]) continue;
    fs.copyFileSync(requireRegularFile(scripts[name], `Debian ${name}`), path.join(controlDirectory, name));
    fs.chmodSync(path.join(controlDirectory, name), 0o755);
  }
  fs.mkdirSync(path.dirname(output), { recursive: true });
  runner('dpkg-deb', ['--root-owner-group', '--build', root, output]);
  if (!fs.existsSync(output)) throw new Error(`dpkg-deb did not create ${output}`);
  return output;
}

export function buildRpmPackage({
  root,
  outputDirectory,
  workDirectory,
  version,
  architecture,
  scripts,
  runner = runChecked,
  extractor = extractRpmPayload
}) {
  if (!['aarch64', 'x86_64'].includes(architecture)) {
    throw new Error(`unsupported RPM architecture: ${architecture}`);
  }
  const top = path.resolve(workDirectory);
  fs.rmSync(top, { recursive: true, force: true });
  for (const directory of ['BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS']) {
    fs.mkdirSync(path.join(top, directory), { recursive: true });
  }
  const sourceArchive = path.join(top, 'SOURCES', 'openburnbar-rootfs.tar.gz');
  runner('tar', [
    '--sort=name',
    '--mtime=@0',
    '--owner=0',
    '--group=0',
    '--numeric-owner',
    '-czf',
    sourceArchive,
    '-C',
    root,
    '.'
  ]);
  fs.writeFileSync(path.join(top, 'SOURCES', 'openburnbar-files.list'), `${rpmOwnedPaths(root).join('\n')}\n`);

  const lifecycle = (name) => scripts[name]
    ? `\n%${name}\n${normalizedScriptBody(scripts[name])}\n`
    : '';
  const spec = [
    // Do not generate a secondary debug package. The release publishes the exact
    // pre-measured binaries as one native package.
    '%global debug_package %{nil}',
    'Name: open-burn-bar',
    `Version: ${version}`,
    'Release: 1%{?dist}',
    'Summary: Local-first AI agent cost and control dashboard',
    'License: AGPL-3.0-only',
    'URL: https://github.com/Imagine-That-Ai/BurnBar',
    `BuildArch: ${architecture}`,
    'Source0: openburnbar-rootfs.tar.gz',
    'Source1: openburnbar-files.list',
    'Requires: gtk3, libsecret, webkit2gtk4.1, libayatana-appindicator-gtk3',
    'Requires(post): systemd',
    'Requires(preun): systemd',
    'Requires(postun): systemd',
    '',
    '%description',
    'OpenBurnBar desktop, local daemon, and fail-closed Linux attestation broker.',
    '',
    '%prep',
    '',
    '%build',
    '',
    '%install',
    'rm -rf %{buildroot}',
    'mkdir -p %{buildroot}',
    'tar -xzf %{SOURCE0} -C %{buildroot}',
    lifecycle('pre'),
    lifecycle('post'),
    lifecycle('preun'),
    lifecycle('postun'),
    '%files -f %{SOURCE1}',
    '',
    '%changelog',
    '* Thu Jul 10 2026 OpenBurnBar Release Engineering <release@openburnbar.dev> - initial native package lifecycle',
    '- Add the root-owned, socket-activated Linux attestation broker foundation.',
    ''
  ].join('\n');
  const specPath = path.join(top, 'SPECS', 'open-burn-bar.spec');
  fs.writeFileSync(specPath, spec);
  // The installed manifest is signed before rpmbuild. Distribution defaults for
  // __os_install_post invoke BRP helpers that may strip or otherwise rewrite ELF
  // files, while RPM's build-id policy may synthesize unmeasured symlinks. Disable
  // both mutation surfaces; the extracted-RPM verification below independently
  // fails closed on any payload drift introduced by rpmbuild or future macros.
  runner('rpmbuild', [
    '--define', `_topdir ${top}`,
    '--define', '__os_install_post %{nil}',
    '--define', '_build_id_links none',
    '--target', architecture,
    '-bb',
    specPath
  ]);
  const candidates = [];
  const stack = [path.join(top, 'RPMS')];
  while (stack.length) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) stack.push(full);
      else if (entry.isFile() && entry.name.endsWith('.rpm')) candidates.push(full);
    }
  }
  if (candidates.length !== 1) throw new Error(`rpmbuild produced ${candidates.length} binary packages`);
  const extractedRoot = path.join(top, 'VERIFYROOT');
  extractor(candidates[0], extractedRoot);
  verifyExtractedRpmPayload({ sourceRoot: root, extractedRoot });
  fs.mkdirSync(outputDirectory, { recursive: true });
  const output = path.join(outputDirectory, `OpenBurnBar-${version}-1.${architecture}.rpm`);
  fs.copyFileSync(candidates[0], output);
  return output;
}

export const __testing__ = {
  extractRpmPayload,
  filesRoot,
  installedFileRecords,
  installedSizeKiB,
  normalizedScriptBody,
  runBinaryChecked,
  runChecked,
  verifyExtractedRpmPayload,
  walk
};
