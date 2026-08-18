import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const HEAD_PATTERN = /^[a-f0-9]{40,64}$/u;

function runGit(repoRoot, args) {
  const result = spawnSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(result.stderr.trim() || `git ${args.join(' ')} failed`);
  }
  return result.stdout;
}

export const NATIVE_ARTIFACT_PATHS = [
  'Vendor/OpenBurnBarSignalFfiIOS.xcframework',
  'Vendor/OpenBurnBarSignalFfi.xcframework',
  'Vendor/openburnbar-iroh.aar',
  'Vendor/opus-android.aar',
  'android/openburnbar-domain-core'
];

function digestPath(root, relative) {
  const full = path.join(root, relative);
  if (!fs.existsSync(full)) {
    return { path: relative, present: false, sha256: null };
  }
  const stat = fs.statSync(full);
  if (stat.isDirectory()) {
    const files = [];
    const walk = (dir) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const next = path.join(dir, entry.name);
        if (entry.isDirectory()) walk(next);
        else if (entry.isFile()) files.push(next);
      }
    };
    walk(full);
    files.sort();
    const hash = crypto.createHash('sha256');
    for (const file of files) {
      hash.update(path.relative(full, file));
      hash.update(fs.readFileSync(file));
    }
    return { path: relative, present: true, sha256: hash.digest('hex') };
  }
  const sha256 = crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex');
  return { path: relative, present: true, sha256 };
}

export function collectNativeArtifactDigests(repoRoot) {
  return NATIVE_ARTIFACT_PATHS.map((relative) => digestPath(repoRoot, relative));
}

export function collectCandidateFingerprint(repoRoot) {
  const commitSha = runGit(repoRoot, ['rev-parse', 'HEAD']).trim();
  if (!HEAD_PATTERN.test(commitSha)) {
    throw new Error(`HEAD is not a canonical git SHA: ${commitSha}`);
  }
  const dirtyEntries = runGit(repoRoot, ['status', '--short'])
    .split('\n')
    .map((line) => line.trimEnd())
    .filter(Boolean);
  return {
    commitSha,
    dirty: dirtyEntries.length > 0,
    dirtyEntries,
    nativeArtifacts: collectNativeArtifactDigests(repoRoot)
  };
}

export function candidateCloseRefusal(fingerprint) {
  if (!fingerprint || typeof fingerprint !== 'object') {
    return 'candidate fingerprint is missing';
  }
  if (!HEAD_PATTERN.test(fingerprint.commitSha ?? '')) {
    return 'candidate commit SHA is not a canonical 40-64 character lowercase git SHA';
  }
  if (fingerprint.dirty === true || (fingerprint.dirtyEntries?.length ?? 0) > 0) {
    return 'dirty tree cannot be a closable candidate';
  }
  return null;
}
