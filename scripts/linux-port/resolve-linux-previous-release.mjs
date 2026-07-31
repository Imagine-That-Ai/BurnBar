#!/usr/bin/env node
/**
 * Resolve the newest Linux release that is safe to use as an installed
 * update/rollback baseline.
 *
 * A release is not a lifecycle baseline merely because it has a matching
 * version tag.  Both architectures must have the package/provenance subjects
 * consumed by the lifecycle probes, and each Debian package must carry the
 * package-owned daemon launcher contract.  This keeps the release workflow
 * from selecting the historical 0.1.0 package, which predates that contract.
 * The lifecycle verifier remains the final authority; this resolver only
 * avoids wasting a shard on an obviously incompatible or partial release.
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const SEMVER = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const TAG = /^linux-v(?<version>(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$/u;
const ARCHITECTURES = ['aarch64', 'x86_64'];
const DEB_ASSET = { aarch64: 'OpenBurnBar_{version}_arm64.deb', x86_64: 'OpenBurnBar_{version}_amd64.deb' };

export function compareSemver(left, right) {
  const a = left.split('.').map(Number);
  const b = right.split('.').map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}

export function expectedAssets(version, architecture) {
  const deb = DEB_ASSET[architecture]?.replace('{version}', version);
  const arch = `openburnbar-${version}-`;
  const installedAttestations = Object.fromEntries(
    ['arch', 'deb', 'rpm'].map((format) => [
      format,
      {
        manifest: `openburnbar-${version}-${format}-${architecture}.installed-manifest.json`,
        signature: `openburnbar-${version}-${format}-${architecture}.installed-manifest.ed25519`
      }
    ])
  );
  return {
    deb,
    archPackage: new RegExp(`^${escapeRegExp(arch)}[0-9]+-${escapeRegExp(architecture)}\\.pkg\\.tar\\.zst$`, 'u'),
    archSignature: new RegExp(`^${escapeRegExp(arch)}[0-9]+-${escapeRegExp(architecture)}\\.pkg\\.tar\\.zst\\.ed25519\\.sig$`, 'u'),
    installedAttestations,
    productProof: 'product-proof-closure.json',
    productProofSignature: 'product-proof-closure.json.ed25519.sig'
  };
}

export function inspectReleaseAssets({ version, assets, architectures = ARCHITECTURES }) {
  const names = new Set(assets.map((asset) => typeof asset === 'string' ? asset : asset?.name).filter(Boolean));
  const failures = [];
  const selected = {};
  for (const architecture of architectures) {
    const expected = expectedAssets(version, architecture);
    if (!names.has(expected.deb)) failures.push(`${architecture}: missing ${expected.deb}`);
    const archPackages = [...names].filter((name) => expected.archPackage.test(name));
    const archSignatures = [...names].filter((name) => expected.archSignature.test(name));
    if (archPackages.length !== 1) failures.push(`${architecture}: expected one canonical Arch package, found ${archPackages.length}`);
    if (archSignatures.length !== 1) failures.push(`${architecture}: expected one detached Arch package signature, found ${archSignatures.length}`);
    for (const format of ['arch', 'deb', 'rpm']) {
      const attestation = expected.installedAttestations[format];
      if (!names.has(attestation.manifest)) {
        failures.push(`${architecture}: missing ${attestation.manifest}`);
      }
      if (!names.has(attestation.signature)) {
        failures.push(`${architecture}: missing ${attestation.signature}`);
      }
    }
    for (const sidecar of ['productProof', 'productProofSignature']) {
      if (!names.has(expected[sidecar])) failures.push(`${architecture}: missing ${expected[sidecar]}`);
    }
    selected[architecture] = {
      deb: expected.deb,
      archPackage: archPackages[0] ?? null,
      archSignature: archSignatures[0] ?? null,
      installedAttestations: expected.installedAttestations
    };
  }
  return { passed: failures.length === 0, failures, selected };
}

export function releaseCandidates({ releases, currentVersion, requestedVersion = '' }) {
  const failures = [];
  const parsed = [];
  for (const release of releases) {
    const tag = typeof release === 'string' ? release : release?.tagName;
    const match = TAG.exec(tag ?? '');
    if (!match || release?.isDraft === true) continue;
    const version = match.groups.version;
    if (!SEMVER.test(version) || compareSemver(version, currentVersion) >= 0) continue;
    parsed.push({ tag, version, prerelease: release?.isPrerelease === true });
  }
  const ordered = parsed.sort((left, right) => compareSemver(right.version, left.version));
  if (requestedVersion) {
    if (!SEMVER.test(requestedVersion)) return { candidates: [], failures: [`previous Linux version must be strict X.Y.Z semver: ${requestedVersion}`] };
    const requested = ordered.filter((entry) => entry.version === requestedVersion);
    if (requested.length === 0) failures.push(`requested Linux baseline linux-v${requestedVersion} was not found as a published release`);
    return { candidates: requested, failures };
  }
  return { candidates: ordered, failures };
}

// A payload check has three outcomes, not two.  "Incompatible" is an
// authoritative verdict about a release; "indeterminate" means the release
// could not be inspected at all (the download or dpkg-deb failed).  Callers
// that treat "no compatible baseline" as authorization must never be handed
// an indeterminate result dressed up as a verdict, so the distinction is
// carried explicitly instead of being collapsed into `passed: false`.
export function assertDebianLifecyclePayload({ packagePath, version, architecture, run = defaultRun }) {
  const fields = [];
  for (const field of ['Package', 'Version', 'Architecture']) {
    const result = run('dpkg-deb', ['-f', packagePath, field]);
    if (result.exitCode !== 0) {
      return { passed: false, indeterminate: true, reason: `${architecture}: dpkg-deb metadata inspection failed` };
    }
    fields.push(result.stdout.trim());
  }
  const expectedArchitecture = architecture === 'aarch64' ? 'arm64' : 'amd64';
  if (fields[0] !== 'open-burn-bar' || fields[1] !== version || fields[2] !== expectedArchitecture) {
    return { passed: false, reason: `${architecture}: Debian package identity is not open-burn-bar ${version} ${expectedArchitecture}` };
  }
  const contents = run('dpkg-deb', ['-c', packagePath]);
  if (contents.exitCode !== 0) {
    return { passed: false, indeterminate: true, reason: `${architecture}: dpkg-deb content inspection failed` };
  }
  if (!contents.stdout.split(/\n/u).some((line) => /(?:^|\s)\.\/usr\/libexec\/openburnbar-daemon-launch$/u.test(line.trim()))) {
    return { passed: false, reason: `${architecture}: Debian package is missing /usr/libexec/openburnbar-daemon-launch` };
  }
  return { passed: true };
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

function defaultRun(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: ROOT,
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
    ...options
  });
  return { exitCode: result.status ?? 1, stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}

function runRequired(command, args, options = {}) {
  const result = defaultRun(command, args, options);
  if (result.exitCode !== 0) throw new Error(`${command} ${args.join(' ')} failed\n${result.stderr || result.stdout}`);
  return result;
}

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1]?.trim() ?? '' : '';
}

function main() {
  const currentVersion = process.env.CURRENT_VERSION?.trim() || argument('--current-version');
  const requestedVersion = process.env.INPUT_PREVIOUS_VERSION?.trim() || argument('--previous-version');
  const repository = process.env.GITHUB_REPOSITORY?.trim() || argument('--repo');
  const tempBase = process.env.RUNNER_TEMP?.trim() || path.join(ROOT, '.tmp', 'linux-previous-baseline');
  fs.mkdirSync(path.resolve(tempBase), { recursive: true });
  const workDir = fs.mkdtempSync(path.join(path.resolve(tempBase), 'resolve-'));
  const output = process.argv.includes('--github-output') && process.env.GITHUB_OUTPUT;
  let result;
  try {
    const list = runRequired('gh', [
      'release', 'list', '--limit', '100', '--json', 'tagName,isDraft,isPrerelease', ...(repository ? ['--repo', repository] : [])
    ]);
    const releases = JSON.parse(list.stdout);
    const selection = releaseCandidates({ releases, currentVersion, requestedVersion });
    const reasons = [...selection.failures];
    let selected = null;
    for (const candidate of selection.candidates) {
      const view = runRequired('gh', [
        'release', 'view', candidate.tag, '--json', 'assets', ...(repository ? ['--repo', repository] : [])
      ]);
      const release = JSON.parse(view.stdout);
      const assets = inspectReleaseAssets({ version: candidate.version, assets: release.assets ?? [] });
      if (!assets.passed) {
        reasons.push(`${candidate.tag}: ${assets.failures.join('; ')}`);
        continue;
      }
      const packageChecks = [];
      for (const architecture of ARCHITECTURES) {
        const packageDir = path.join(workDir, candidate.version, architecture);
        fs.mkdirSync(packageDir, { recursive: true });
        const assetName = assets.selected[architecture].deb;
        const download = defaultRun('gh', [
          'release', 'download', candidate.tag, '--pattern', assetName, '--dir', packageDir, '--clobber', ...(repository ? ['--repo', repository] : [])
        ]);
        const packagePath = path.join(packageDir, assetName);
        if (download.exitCode !== 0 || !fs.existsSync(packagePath)) {
          // A failed download proves nothing about the release; it is a
          // discovery failure, not evidence that no baseline exists.
          packageChecks.push({
            passed: false,
            indeterminate: true,
            reason: `${architecture}: failed to download ${assetName} for payload inspection`
          });
          continue;
        }
        packageChecks.push(assertDebianLifecyclePayload({ packagePath, version: candidate.version, architecture }));
      }
      const failedChecks = packageChecks.filter((check) => !check.passed);
      const indeterminate = failedChecks.filter((check) => check.indeterminate === true);
      if (indeterminate.length > 0) {
        throw new Error(`${candidate.tag}: ${indeterminate.map((check) => check.reason).join('; ')}`);
      }
      if (failedChecks.length > 0) {
        reasons.push(`${candidate.tag}: ${failedChecks.map((check) => check.reason).join('; ')}`);
        continue;
      }
      selected = candidate;
      break;
    }
    result = {
      passed: selected !== null,
      version: selected?.version ?? '',
      tag: selected?.tag ?? '',
      reason: selected ? 'selected newest published two-architecture release with a compatible Debian lifecycle payload' : reasons.join(' | ') || 'no published compatible Linux baseline was found'
    };
    if (requestedVersion && !selected) result.reason = `requested baseline ${requestedVersion} is not lifecycle-compatible: ${result.reason}`;
  } catch (error) {
    result = { passed: false, version: '', tag: '', discoveryError: true, reason: error.message };
  } finally {
    fs.rmSync(workDir, { recursive: true, force: true });
  }
  if (output) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `version=${result.version}\ntag=${result.tag}\nreason=${result.reason.replace(/[\r\n]/gu, ' ')}\n`);
  }
  console.log(JSON.stringify(result, null, 2));
  // Automatic discovery may legitimately return no baseline during the first
  // release.  Keep the shard green and let the existing explicit blocked
  // lifecycle report explain the promotion state.  A strict but incompatible
  // requested release is also retained as a blocked input so prerelease runs
  // still produce honest evidence; only malformed semver is an input error.
  // Under --strict, a transient discovery failure (for example a gh API
  // outage) is fatal: consumers that treat "no baseline" as an authorization
  // signal must never mistake an error for an authoritative empty result.
  if (process.argv.includes('--strict') && result.discoveryError === true) process.exit(1);
  process.exit(requestedVersion && !SEMVER.test(requestedVersion) ? 1 : 0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
