import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
/** Sealed historical mission-001 release evidence — do not rewrite during local gates. */
export const releaseEvidenceDir = path.join(repoRoot, 'docs/linux-port/evidence/mission-001-release');
/** Mutable reanchor / local-gate evidence (Phase 0+). Prefer this for validator outputs. */
export const reanchorEvidenceDir = path.join(repoRoot, 'docs/linux-port/evidence/mission-002-reanchor');
export const manifestPath = path.join(repoRoot, 'packaging/linux/release-manifest.json');

export function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

export function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
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
