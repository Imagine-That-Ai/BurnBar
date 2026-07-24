import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
/** Sealed historical mission-001 release evidence — do not rewrite during local gates. */
export const releaseEvidenceDir = path.join(repoRoot, 'docs/linux-port/evidence/mission-001-release');
/** Mutable local/CI evidence. CI sets this to a fresh runner-temporary directory. */
export const reanchorEvidenceDir = process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT
  ? path.resolve(repoRoot, process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT)
  : path.join(repoRoot, 'docs/linux-port/evidence/mission-002-reanchor');
export const manifestPath = path.join(repoRoot, 'packaging/linux/release-manifest.json');
export const linuxReleaseWorkflowIdentity = 'https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-release.yml';

const linuxReleaseTagPattern = /^linux-v([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$/u;
const runStepBareCommands = new Set([
  'bash',
  'cargo',
  'cosign',
  'dpkg',
  'dpkg-deb',
  'git',
  'node',
  'npm',
  'pacman',
  'python3',
  'rpm',
  'sudo',
  'swift',
  'unsquashfs'
]);
const absoluteRunStepCommands = new Set([
  '/usr/bin/openburnbar-daemon',
  '/usr/bin/openburnbar-linux-desktop',
  '/usr/libexec/openburnbar-daemon-launch'
]);
const runStepBashInlineScripts = new Set([
  'command -v secret-tool || true',
  'command -v kwallet-query || true'
]);
const runStepSudoCommands = new Set(['dpkg', 'pacman', 'rpm']);
const defaultRunStepMaxBuffer = 64 * 1024 * 1024;
const maxRunStepMaxBuffer = 512 * 1024 * 1024;

function isInside(parent, candidate) {
  const relativePath = path.relative(parent, candidate);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
}

function validateRunStepToken(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value.includes('\0')) {
    throw new Error(`Invalid ${label} for Linux release step`);
  }
  return value;
}

function validateRunStepCommand(command) {
  const value = validateRunStepToken(command, 'command');
  if (runStepBareCommands.has(value)) return value;
  if (!path.isAbsolute(value)) throw new Error(`Linux release step command is not allowlisted: ${value}`);
  const resolved = path.resolve(value);
  if (absoluteRunStepCommands.has(resolved) || isInside(repoRoot, resolved)) return resolved;
  throw new Error(`Linux release step command is outside the trusted command roots: ${value}`);
}

function validateRunStepArgs(args) {
  if (!Array.isArray(args)) throw new Error('Linux release step args must be an array');
  return args.map((arg, index) => {
    const value = validateRunStepToken(String(arg), `arg ${index}`);
    if (value.length > 8192) throw new Error(`Linux release step arg ${index} is too long`);
    return value;
  });
}

function validateRunStepCommandArgs(command, args) {
  if (command !== 'bash') return args;
  const [flag, inlineScript, ...rest] = args;
  if (flag === '-c' || flag === '-lc') {
    if (rest.length > 0 || !runStepBashInlineScripts.has(inlineScript)) {
      throw new Error('Linux release step bash inline script is not allowlisted');
    }
  }
  return args;
}

function validateRunStepSudoArgs(command, args) {
  if (command !== 'sudo') return args;
  if (!runStepSudoCommands.has(args[0])) {
    throw new Error(`Linux release step sudo command is not allowlisted: ${args[0] ?? '<missing>'}`);
  }
  return args;
}

function validateRunStepCwd(cwd) {
  const resolved = path.resolve(cwd ?? repoRoot);
  if (!isInside(repoRoot, resolved)) throw new Error(`Linux release step cwd is outside the repo: ${resolved}`);
  return resolved;
}

function validateRunStepEnv(env) {
  const source = env ?? process.env;
  const out = {};
  for (const [key, value] of Object.entries(source)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/u.test(key)) throw new Error(`Invalid Linux release env key: ${key}`);
    if (value === undefined) continue;
    const stringValue = String(value);
    if (stringValue.includes('\0')) throw new Error(`Invalid Linux release env value for ${key}`);
    out[key] = stringValue;
  }
  return out;
}

function validateRunStepByteLimit(value, label, { fallback, minimum = 0, maximum }) {
  const limit = value ?? fallback;
  if (!Number.isSafeInteger(limit) || limit < minimum || limit > maximum) {
    throw new Error(`Linux release step ${label} must be an integer between ${minimum} and ${maximum}`);
  }
  return limit;
}

function truncateUtf8(value, limit) {
  const bytes = Buffer.byteLength(value, 'utf8');
  if (limit === undefined || bytes <= limit) {
    return { value, bytes, truncated: false };
  }

  let used = 0;
  let end = 0;
  while (end < value.length) {
    const codePoint = value.codePointAt(end);
    const width = codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
    if (used + width > limit) break;
    used += width;
    end += codePoint > 0xffff ? 2 : 1;
  }
  return { value: value.slice(0, end), bytes, truncated: true };
}

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

function workflowRefIdentity(workflowRef) {
  const value = String(workflowRef ?? '').trim();
  if (!value) return '';
  const identity = value.startsWith('https://') ? value : `https://github.com/${value}`;
  const prefix = `${linuxReleaseWorkflowIdentity}@`;
  if (!identity.startsWith(prefix)) {
    throw new Error(`Linux release cosign identity is outside the trusted workflow: ${identity}`);
  }
  const ref = identity.slice(prefix.length);
  if (!/^refs\/(?:heads|tags)\/[A-Za-z0-9._/-]+$/u.test(ref)) {
    throw new Error(`Linux release cosign identity has an invalid workflow ref: ${ref}`);
  }
  return identity;
}

/**
 * Resolve the identity Fulcio put in the certificate for this workflow run.
 * Branch candidates are signed by the workflow ref, while published tags use
 * the immutable linux-vX.Y.Z identity from the release manifest.
 */
export function expectedLinuxCosignIdentity({ manifest, version, candidate = false, env = process.env } = {}) {
  const tagIdentity = manifest?.signing?.cosignIdentityTemplate?.replace('{version}', version ?? '');
  if (!candidate) return tagIdentity;

  const supplied = String(env.OPENBURNBAR_LINUX_COSIGN_IDENTITY ?? '').trim();
  const workflowIdentity = workflowRefIdentity(env.GITHUB_WORKFLOW_REF);
  if (supplied && workflowIdentity && supplied !== workflowIdentity) {
    throw new Error('Linux release cosign identity does not match GITHUB_WORKFLOW_REF.');
  }
  const identity = workflowRefIdentity(supplied || workflowIdentity);
  if (!identity) {
    if (env.GITHUB_ACTIONS === 'true') {
      throw new Error('Linux release candidate cosign identity is missing in GitHub Actions.');
    }
    return tagIdentity;
  }
  const ref = identity.slice(`${linuxReleaseWorkflowIdentity}@`.length);
  if (ref.startsWith('refs/tags/')) {
    const tag = ref.slice('refs/tags/'.length);
    parseLinuxReleaseTag(tag);
    if (tag !== `linux-v${version}`) {
      throw new Error(`Linux release candidate tag identity does not match version ${version}: ${tag}`);
    }
  }
  return identity;
}

export function runStep(command, args, options = {}) {
  const safeCommand = validateRunStepCommand(command);
  const safeArgs = validateRunStepSudoArgs(
    safeCommand,
    validateRunStepCommandArgs(safeCommand, validateRunStepArgs(args))
  );
  const safeCwd = validateRunStepCwd(options.cwd);
  const safeEnv = validateRunStepEnv(options.env);
  const maxBuffer = validateRunStepByteLimit(options.maxBuffer, 'maxBuffer', {
    fallback: defaultRunStepMaxBuffer,
    minimum: 1,
    maximum: maxRunStepMaxBuffer
  });
  const outputLimitBytes = options.outputLimitBytes === undefined
    ? undefined
    : validateRunStepByteLimit(options.outputLimitBytes, 'outputLimitBytes', {
      fallback: undefined,
      maximum: maxBuffer
    });
  const result = spawnSync(safeCommand, safeArgs, {
    cwd: safeCwd,
    env: safeEnv,
    encoding: 'utf8',
    maxBuffer
  });
  const rawStdout = result.stdout ?? '';
  const rawStderr = [
    result.stderr ?? '',
    result.error ? `${result.error.name}: ${result.error.message}` : ''
  ].filter(Boolean).join('\n');
  const stdout = truncateUtf8(rawStdout, outputLimitBytes);
  const stderr = truncateUtf8(rawStderr, outputLimitBytes);
  return {
    command: [safeCommand, ...safeArgs].join(' '),
    cwd: path.relative(repoRoot, safeCwd) || '.',
    exitCode: result.status ?? 1,
    stdout: stdout.value,
    stderr: stderr.value,
    ...(stdout.truncated
      ? { stdoutTruncated: true, stdoutBytes: stdout.bytes, stdoutLimitBytes: outputLimitBytes }
      : {}),
    ...(stderr.truncated
      ? { stderrTruncated: true, stderrBytes: stderr.bytes, stderrLimitBytes: outputLimitBytes }
      : {})
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
        : lower.endsWith('.pkg.tar.zst')
          ? 'arch'
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
