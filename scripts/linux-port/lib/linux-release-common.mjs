import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
export const releaseEvidenceDir = path.join(repoRoot, 'docs/linux-port/evidence/mission-001-release');
export const manifestPath = path.join(repoRoot, 'packaging/linux/release-manifest.json');
export const linuxReleaseWorkflowIdentity = 'https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-release.yml';

const linuxReleaseTagPattern = /^linux-v([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$/u;

export function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

export function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

export function parseLinuxReleaseTag(tag) {
  const match = linuxReleaseTagPattern.exec(tag);
  if (!match) {
    throw new Error(`Invalid Linux release tag: ${tag} (expected linux-vMAJOR.MINOR.PATCH[-prerelease][+build])`);
  }
  const version = match[1];
  const [coreAndPrerelease, build] = version.split('+');
  const prereleaseSeparator = coreAndPrerelease.indexOf('-');
  const core = prereleaseSeparator === -1
    ? coreAndPrerelease
    : coreAndPrerelease.slice(0, prereleaseSeparator);
  const prerelease = prereleaseSeparator === -1
    ? undefined
    : coreAndPrerelease.slice(prereleaseSeparator + 1);
  const coreParts = core.split('.');
  if (coreParts[0].length > 3 || coreParts.some((part) => part.length > 1 && part.startsWith('0'))) {
    throw new Error(`Invalid Linux release tag: ${tag} (numeric identifiers cannot have leading zeroes; MAJOR is capped at 999)`);
  }
  for (const [kind, identifiers] of [['prerelease', prerelease], ['build', build]]) {
    if (identifiers?.split('.').some((identifier) => !identifier)) {
      throw new Error(`Invalid Linux release tag: ${tag} (${kind} identifiers cannot be empty)`);
    }
  }
  if (prerelease?.split('.').some((identifier) => /^\d+$/u.test(identifier) && identifier.length > 1 && identifier.startsWith('0'))) {
    throw new Error(`Invalid Linux release tag: ${tag} (numeric prerelease identifiers cannot have leading zeroes)`);
  }
  return version;
}

export function expectedLinuxReleaseIdentity(ref) {
  if (!ref.startsWith('refs/tags/')) {
    throw new Error(`Linux release identity requires a tag ref, received: ${ref}`);
  }
  parseLinuxReleaseTag(ref.slice('refs/tags/'.length));
  return `${linuxReleaseWorkflowIdentity}@${ref}`;
}

export function runStep(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    env: options.env ?? process.env,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024
  });
  return {
    command: [command, ...args].join(' '),
    cwd: path.relative(repoRoot, options.cwd ?? repoRoot) || '.',
    exitCode: result.status ?? 1,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? ''
  };
}

export function sha256(file) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(file));
  return hash.digest('hex');
}

export function verifyEd25519Signature(artifact, signature, publicKeyPem) {
  const publicKey = publicKeyPem?.type === 'public'
    ? publicKeyPem
    : crypto.createPublicKey(publicKeyPem);
  if (publicKey.asymmetricKeyType !== 'ed25519') return false;
  return crypto.verify(null, artifact, publicKey, signature);
}

export function fileSize(file) {
  return fs.statSync(file).size;
}

export function gitInfo() {
  const commitStep = runStep('git', ['rev-parse', 'HEAD']);
  const branchStep = runStep('git', ['branch', '--show-current']);
  const statusStep = runStep('git', ['status', '--porcelain=v1']);
  const remoteStep = runStep('git', ['remote', 'get-url', 'origin']);
  const commit = commitStep.stdout.trim() || process.env.OPENBURNBAR_GIT_COMMIT || 'unknown';
  const branch = branchStep.stdout.trim() || process.env.OPENBURNBAR_GIT_BRANCH || 'unknown';
  const status = statusStep.exitCode === 0
    ? statusStep.stdout.split('\n').filter(Boolean)
    : ['git-status-unavailable'];
  const remote = remoteStep.stdout.trim() || process.env.OPENBURNBAR_GIT_REMOTE || 'unknown';
  return {
    commit,
    branch,
    remote,
    dirty: status.length > 0,
    dirtyEntries: status,
    gitAvailable: commitStep.exitCode === 0 && statusStep.exitCode === 0
  };
}

export function packageVersion() {
  const pkg = readJson(path.join(repoRoot, 'apps/linux-desktop/package.json'));
  return pkg.version;
}

export function discoverBundleArtifacts() {
  const bundleRoot = path.join(repoRoot, 'apps/linux-desktop/src-tauri/target/release/bundle');
  if (!fs.existsSync(bundleRoot)) return [];
  const out = [];
  const stack = [bundleRoot];
  while (stack.length) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
        continue;
      }
      const lower = entry.name.toLowerCase();
      const type = lower.endsWith('.appimage')
        ? 'appimage'
        : lower.endsWith('.deb')
          ? 'deb'
          : lower.endsWith('.rpm')
            ? 'rpm'
            : null;
      if (type) out.push({ type, file: full });
    }
  }
  return out.sort((a, b) => a.file.localeCompare(b.file));
}

export function copyArtifact(src, destDir) {
  fs.mkdirSync(destDir, { recursive: true });
  const dest = path.join(destDir, path.basename(src));
  fs.copyFileSync(src, dest);
  return dest;
}

export function requireFiles(paths) {
  return paths.map((file) => ({
    file,
    exists: fs.existsSync(path.join(repoRoot, file))
  }));
}

export function relative(file) {
  return path.relative(repoRoot, file);
}
