import crypto from 'node:crypto';
import fs from 'node:fs';

export const P31_REQUIREMENT_ID = 'P-31';
export const P31_ROLES = Object.freeze([
  'feature.accessibility-assistive-tech',
  'feature.accessibility-contrast',
  'feature.accessibility-motion',
  'feature.accessibility-scale'
]);

export const P31_ENVIRONMENTS = Object.freeze({
  'ubuntu-24.04-gnome-x11-x86_64': {
    os: 'Ubuntu 24.04', desktop: 'GNOME', session: 'X11', architecture: 'x86_64'
  },
  'ubuntu-24.04-gnome-x11-aarch64': {
    os: 'Ubuntu 24.04', desktop: 'GNOME', session: 'X11', architecture: 'aarch64'
  },
  'ubuntu-24.04-gnome-wayland-x86_64': {
    os: 'Ubuntu 24.04', desktop: 'GNOME', session: 'Wayland', architecture: 'x86_64'
  },
  'ubuntu-24.04-gnome-wayland-aarch64': {
    os: 'Ubuntu 24.04', desktop: 'GNOME', session: 'Wayland', architecture: 'aarch64'
  },
  'fedora-kde-wayland-x86_64': {
    os: 'Fedora', desktop: 'KDE Plasma', session: 'Wayland', architecture: 'x86_64'
  },
  'fedora-kde-wayland-aarch64': {
    os: 'Fedora', desktop: 'KDE Plasma', session: 'Wayland', architecture: 'aarch64'
  },
  'arch-sway-wayland-x86_64': {
    os: 'Arch Linux', desktop: 'Sway/wlroots', session: 'Wayland', architecture: 'x86_64'
  }
});

export const P31_REQUIRED_ROUTES = Object.freeze([
  'overview', 'insights', 'database', 'providers', 'projects', 'missions',
  'activity', 'chat', 'memory', 'settings', 'account', 'updates', 'support',
  'onboarding', 'pet', 'text-expansion', 'computer-use', 'mercury', 'smarthub'
]);

const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const CANDIDATE_DIGEST = /^sha256:[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const FORBIDDEN_EVIDENCE = /(?:xvfb|synthetic|fixture|mock)/iu;

function exactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(`${label} fields must be exactly: ${wanted.join(', ')}`);
  }
}

function parseJson(bytes, label) {
  try {
    return JSON.parse(Buffer.from(bytes).toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function sortedUnique(values, label) {
  if (!Array.isArray(values) || values.length === 0 || values.some((value) => typeof value !== 'string' || value.length === 0)) {
    throw new Error(`${label} must be a non-empty string array`);
  }
  const unique = [...new Set(values)].sort();
  if (unique.length !== values.length) throw new Error(`${label} must not contain duplicates`);
  return unique;
}

function evidencePaths(value, label) {
  const paths = sortedUnique(value, label);
  for (const evidencePath of paths) {
    if (evidencePath.startsWith('/') || evidencePath.includes('\\') || FORBIDDEN_EVIDENCE.test(evidencePath)) {
      throw new Error(`${label} contains a forbidden or non-portable path`);
    }
  }
  return paths;
}

function expectedEnvironment(environmentId) {
  const expected = P31_ENVIRONMENTS[environmentId];
  if (!expected) throw new Error(`unknown P-31 support environment: ${environmentId}`);
  return expected;
}

function assertCandidate(candidate, targetHead, candidateRunId, candidateArtifactDigest, label) {
  exactKeys(candidate, ['artifactDigest', 'runId'], `${label} candidate`);
  if (!RUN_ID.test(String(candidate.runId ?? '')) || String(candidate.runId) !== String(candidateRunId)) {
    throw new Error(`${label} candidate run id is not invocation-bound`);
  }
  if (!CANDIDATE_DIGEST.test(candidate.artifactDigest ?? '') || candidate.artifactDigest !== candidateArtifactDigest) {
    throw new Error(`${label} candidate artifact digest is not invocation-bound`);
  }
  if (!HEAD.test(targetHead)) throw new Error(`${label} target HEAD is invalid`);
}

function assertModeClaim(value, label, expectedMode) {
  exactKeys(value, ['evidencePath', 'mode', 'observed', 'pass', 'test'], label);
  if (value.mode !== expectedMode || value.observed !== true || value.pass !== true
      || typeof value.test !== 'string' || value.test.length === 0) {
    throw new Error(`${label} did not pass its ${expectedMode} observation`);
  }
  if (value.evidencePath.startsWith('/') || FORBIDDEN_EVIDENCE.test(value.evidencePath)) {
    throw new Error(`${label} evidence path is not a live installed-session artifact`);
  }
}

function validateScale(observation) {
  exactKeys(observation, [
    'accessibilityTreeObserved', 'clippedCount', 'exactScaleObservable', 'evidencePaths',
    'focusPreserved', 'horizontalScrollbars', 'method', 'observedPercent',
    'overflowCount', 'reflowPass', 'requestedPercent'
  ], 'P-31 scale observation');
  if (observation.requestedPercent !== 200 || observation.observedPercent !== 200
      || observation.exactScaleObservable !== true || observation.reflowPass !== true
      || observation.accessibilityTreeObserved !== true || observation.focusPreserved !== true
      || observation.clippedCount !== 0 || observation.overflowCount !== 0
      || observation.horizontalScrollbars !== 0 || typeof observation.method !== 'string'
      || !/installed.*(?:webkit|browser|desktop)/iu.test(observation.method)) {
    throw new Error('P-31 requires exact 200% scale with reflow, focus, and overflow proof');
  }
  evidencePaths(observation.evidencePaths, 'P-31 scale evidencePaths');
}

function validateContrast(observation) {
  exactKeys(observation, ['evidencePaths', 'forcedColors', 'highContrast', 'method', 'noColor', 'semanticContrastPass'], 'P-31 contrast observation');
  assertModeClaim(observation.forcedColors, 'P-31 forced-colors observation', 'forced-colors');
  assertModeClaim(observation.highContrast, 'P-31 high-contrast observation', 'high-contrast');
  assertModeClaim(observation.noColor, 'P-31 no-color observation', 'no-color');
  if (observation.semanticContrastPass !== true || typeof observation.method !== 'string'
      || !/installed.*(?:contrast|color)/iu.test(observation.method)) {
    throw new Error('P-31 contrast proof must come from the installed candidate');
  }
  evidencePaths(observation.evidencePaths, 'P-31 contrast evidencePaths');
}

function validateMotion(observation) {
  exactKeys(observation, [
    'animationsObserved', 'evidencePaths', 'mediaQuery', 'method', 'reducedMotion',
    'runtimeStylesPass', 'transitionsObserved'
  ], 'P-31 motion observation');
  exactKeys(observation.reducedMotion, ['enabled', 'observed', 'pass'], 'P-31 reduced-motion observation');
  if (observation.reducedMotion.enabled !== true || observation.reducedMotion.observed !== true
      || observation.reducedMotion.pass !== true || observation.animationsObserved !== 0
      || observation.transitionsObserved !== 0 || observation.runtimeStylesPass !== true
      || observation.mediaQuery !== '(prefers-reduced-motion: reduce)'
      || typeof observation.method !== 'string' || !/installed.*motion/iu.test(observation.method)) {
    throw new Error('P-31 reduced-motion proof must disable nonessential animation and transitions');
  }
  evidencePaths(observation.evidencePaths, 'P-31 motion evidencePaths');
}

function validateAssistive(observation) {
  exactKeys(observation, ['evidencePaths', 'keyboard', 'liveRegionsAnnounced', 'method', 'routesCovered', 'screenReader'], 'P-31 assistive observation');
  exactKeys(observation.keyboard, [
    'distinctFocusedTargets', 'focusTrap', 'namedFocusedTargets', 'pass',
    'physicalKeyPressCount', 'stepCount'
  ], 'P-31 keyboard observation');
  if (observation.keyboard.pass !== true || observation.keyboard.focusTrap !== false
      || observation.keyboard.physicalKeyPressCount < 10 || observation.keyboard.stepCount < 10
      || observation.keyboard.distinctFocusedTargets < 3 || observation.keyboard.namedFocusedTargets < 3) {
    throw new Error('P-31 keyboard evidence did not prove a usable focus traversal');
  }
  exactKeys(observation.screenReader, ['announcementsObserved', 'name', 'processObserved', 'treeObserved'], 'P-31 screen-reader observation');
  if (observation.screenReader.processObserved !== true || observation.screenReader.treeObserved !== true
      || observation.screenReader.announcementsObserved !== true
      || !/orca|speech dispatcher|kde screen reader/iu.test(observation.screenReader.name ?? '')) {
    throw new Error('P-31 requires a live Linux screen-reader observation');
  }
  if (observation.liveRegionsAnnounced !== true) throw new Error('P-31 live-region announcements are missing');
  const routes = sortedUnique(observation.routesCovered, 'P-31 routesCovered');
  const expected = [...P31_REQUIRED_ROUTES].sort();
  if (routes.length !== expected.length || routes.some((route, index) => route !== expected[index])) {
    throw new Error('P-31 assistive evidence must cover every Linux route');
  }
  evidencePaths(observation.evidencePaths, 'P-31 assistive evidencePaths');
}

function validateDesktop(desktop, environmentId) {
  exactKeys(desktop, ['compositor', 'desktop', 'liveSession', 'session'], 'P-31 desktop observation');
  const expected = expectedEnvironment(environmentId);
  if (desktop.desktop !== expected.desktop || desktop.session !== expected.session
      || desktop.liveSession !== true || typeof desktop.compositor !== 'string'
      || desktop.compositor.length === 0 || FORBIDDEN_EVIDENCE.test(desktop.compositor)) {
    throw new Error('P-31 desktop observation is not a live supported Linux session');
  }
}

export function validateP31LiveSession(document, {
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest
}) {
  exactKeys(document, [
    'candidate', 'desktop', 'environmentId', 'id', 'observations', 'package',
    'requirementId', 'schemaVersion', 'targetHead'
  ], 'P-31 live accessibility session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p31-live-session-v1'
      || document.requirementId !== P31_REQUIREMENT_ID || document.environmentId !== environmentId
      || document.targetHead !== targetHead || !HEAD.test(document.targetHead ?? '')) {
    throw new Error('P-31 live session is not invocation-bound');
  }
  assertCandidate(document.candidate, targetHead, candidateRunId, candidateArtifactDigest, 'P-31 live session');
  exactKeys(document.package, ['architecture', 'format', 'installed', 'manifestSha256', 'source', 'version'], 'P-31 package observation');
  const expected = expectedEnvironment(environmentId);
  if (document.package.architecture !== expected.architecture || document.package.installed !== true
      || document.package.source !== 'signed-installed-candidate' || !SHA256.test(document.package.manifestSha256 ?? '')
      || typeof document.package.version !== 'string' || document.package.version.length === 0) {
    throw new Error('P-31 package observation is not the signed installed candidate');
  }
  validateDesktop(document.desktop, environmentId);
  exactKeys(document.observations, ['assistiveTech', 'contrast', 'motion', 'scale'], 'P-31 observations');
  validateScale(document.observations.scale);
  validateContrast(document.observations.contrast);
  validateMotion(document.observations.motion);
  validateAssistive(document.observations.assistiveTech);
  return document;
}

export function buildP31Proof({ role, session, sourcePath, sourceSha256 }) {
  if (!P31_ROLES.includes(role)) throw new Error(`unknown P-31 role: ${role}`);
  const observationKey = role.slice('feature.accessibility-'.length)
    .replace('assistive-tech', 'assistiveTech');
  return {
    schemaVersion: 1,
    id: `openburnbar-linux-p31-${observationKey}-proof-v1`,
    requirementId: P31_REQUIREMENT_ID,
    role,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    desktop: session.desktop,
    source: {
      path: sourcePath,
      sha256: sourceSha256,
      method: 'live-installed-candidate-accessibility-session'
    },
    claim: session.observations[observationKey]
  };
}

export function validateP31Proof(document, {
  role,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest
}) {
  exactKeys(document, [
    'candidate', 'claim', 'desktop', 'environmentId', 'id', 'requirementId',
    'role', 'schemaVersion', 'source', 'targetHead'
  ], `${role} proof`);
  if (document.schemaVersion !== 1 || document.requirementId !== P31_REQUIREMENT_ID
      || document.role !== role || document.environmentId !== environmentId
      || document.targetHead !== targetHead || !HEAD.test(targetHead ?? '')) {
    throw new Error(`${role} proof is not invocation-bound`);
  }
  assertCandidate(document.candidate, targetHead, candidateRunId, candidateArtifactDigest, role);
  validateDesktop(document.desktop, environmentId);
  exactKeys(document.source, ['method', 'path', 'sha256'], `${role} proof source`);
  if (document.source.method !== 'live-installed-candidate-accessibility-session'
      || typeof document.source.path !== 'string' || document.source.path.startsWith('/')
      || !SHA256.test(document.source.sha256 ?? '')) {
    throw new Error(`${role} proof source is not a canonical live-session record`);
  }
  if (role.endsWith('scale')) validateScale(document.claim);
  else if (role.endsWith('contrast')) validateContrast(document.claim);
  else if (role.endsWith('motion')) validateMotion(document.claim);
  else validateAssistive(document.claim);
  return document;
}

export function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

export function parseP31Json(bytes, label) {
  return parseJson(bytes, label);
}

export function readP31Json(file, label) {
  return parseP31Json(fs.readFileSync(file), label);
}
