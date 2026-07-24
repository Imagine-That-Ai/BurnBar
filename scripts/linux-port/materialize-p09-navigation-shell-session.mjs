#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  INSTALLED_UI_ENVIRONMENTS,
  artifactRecord,
  atomicWriteJson,
  exactKeys,
  parseJson
} from './lib/installed-ui-proof.mjs';
import { P09_REQUIRED_ROUTES, P09_SESSION_FILENAME, validateP09InstalledSession } from './lib/p09-navigation-shell-proof.mjs';
import { INSTALLED_MANIFEST_PATH, INSTALLED_MANIFEST_SIGNATURE_PATH } from './lib/linux-installed-manifest.mjs';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const LABELS = [
  'Overview', 'Insights', 'Database', 'Providers & models', 'Projects', 'Missions',
  'Activity & logs', 'Chat / Hermes', 'Memory', 'Settings', 'Account & sync', 'Updates',
  'Support & diagnostics', 'First-run setup', 'Pet companion', 'Text expansion',
  'Computer Use', 'Mercury', 'SmartHub / IoT'
];

function copyRaw(repoRoot, sourceRoot, inputRoot, sourceName, targetName, environmentId, label) {
  if (path.basename(sourceName) !== sourceName || path.basename(targetName) !== targetName) throw new Error(`${label} name must be a basename`);
  const source = path.join(sourceRoot, sourceName);
  const stat = fs.lstatSync(source);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${label} source must be a regular non-symlink file`);
  const destination = path.join(inputRoot, 'raw', targetName);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  return artifactRecord(repoRoot, destination, 'P-09', environmentId, label);
}

function timestampsFromJson(record, repoRoot, field = 'events') {
  const document = parseJson(fs.readFileSync(path.join(repoRoot, record.path)), record.path);
  const values = field === 'capturedAt' ? [document.capturedAt] : (document[field] ?? []).map((row) => row.at);
  return values.map(Date.parse).filter(Number.isFinite);
}

export function materializeP09NavigationShellSession(options, {
  installedVerifier = verifyInstalledCandidate,
  manifestPath = INSTALLED_MANIFEST_PATH,
  signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH
} = {}) {
  const repoRoot = fs.realpathSync(options.repoRoot ?? DEFAULT_REPO_ROOT);
  const inputRoot = fs.realpathSync(options.outputRoot);
  const shellRoot = fs.realpathSync(options.shellEvidenceDir);
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error('P-09 materializer requires a supported environment');
  installedVerifier(options);
  if (!options.compositor || /(?:xvfb|xfce|synthetic|mock)/iu.test(options.compositor)) {
    throw new Error('P-09 materializer requires the real compositor identity');
  }
  const manifest = copyRaw(repoRoot, path.dirname(manifestPath), inputRoot, path.basename(manifestPath), 'installed-manifest.json', options.environmentId, 'P-09 installed manifest');
  const signature = copyRaw(repoRoot, path.dirname(signaturePath), inputRoot, path.basename(signaturePath), 'installed-manifest.json.sig', options.environmentId, 'P-09 installed manifest signature');
  if (manifest.sha256 !== options.manifestSha256 || signature.sha256 !== options.manifestSignatureSha256) {
    throw new Error('P-09 installed attestation copy changed from the selected candidate');
  }
  const transcript = parseJson(fs.readFileSync(path.join(shellRoot, 'packaged-route-session-transcript.json')), 'P-09 packaged route transcript');
  exactKeys(transcript, [
    'appPid', 'desktop', 'displayServer', 'environmentId', 'manifestSha256',
    'mode', 'producer', 'routes', 'surface'
  ], 'P-09 packaged route transcript');
  if (transcript.mode !== 'packaged-desktop-route-navigation'
      || transcript.producer !== 'openburnbar-p09-native-route-probe-v1'
      || transcript.surface !== 'installed-tauri-native-session'
      || transcript.environmentId !== options.environmentId || transcript.desktop !== expected.desktop
      || transcript.displayServer !== expected.session || transcript.manifestSha256 !== manifest.sha256
      || !Number.isSafeInteger(transcript.appPid) || transcript.appPid < 1
      || !Array.isArray(transcript.routes)
      || transcript.routes.length !== P09_REQUIRED_ROUTES.length) {
    throw new Error('P-09 packaged route transcript is incomplete');
  }
  const perfSamples = copyRaw(repoRoot, shellRoot, inputRoot, 'runtime-perf-samples.jsonl', 'runtime-perf-samples.jsonl', options.environmentId, 'P-09 route performance');
  const times = [];
  const routes = transcript.routes.map((row, index) => {
    exactKeys(row, [
      'appPid', 'atspi', 'capturedAt', 'desktop', 'displayServer', 'manifestSha256',
      'navMethod', 'route', 'screenshot', 'surface', 'windowId', 'xwininfo'
    ], `P-09 transcript route ${index}`);
    if (row.route !== P09_REQUIRED_ROUTES[index] || row.navMethod !== 'atspi-command-palette-actions'
        || row.surface !== transcript.surface || row.appPid !== transcript.appPid
        || row.desktop !== transcript.desktop || row.displayServer !== transcript.displayServer
        || row.manifestSha256 !== manifest.sha256 || typeof row.windowId !== 'string'
        || !Number.isFinite(Date.parse(row.capturedAt))) {
      throw new Error(`P-09 transcript route ${index} was not activated through AT-SPI`);
    }
    const atspi = copyRaw(repoRoot, shellRoot, inputRoot, row.atspi, `route-${row.route}-atspi.json`, options.environmentId, `P-09 ${row.route} AT-SPI`);
    times.push(...timestampsFromJson(atspi, repoRoot, 'capturedAt'));
    return {
      index, route: row.route, expectedName: LABELS[index], activated: true,
      appPid: row.appPid, windowId: row.windowId, capturedAt: row.capturedAt,
      navMethod: row.navMethod,
      atspi,
      screenshot: copyRaw(repoRoot, shellRoot, inputRoot, row.screenshot, `route-${row.route}.png`, options.environmentId, `P-09 ${row.route} screenshot`),
      window: copyRaw(repoRoot, shellRoot, inputRoot, row.xwininfo, `route-${row.route}-window.json`, options.environmentId, `P-09 ${row.route} window`)
    };
  });
  const deepLinks = ['provider', 'model'].map((kind) => {
    const eventLog = copyRaw(repoRoot, shellRoot, inputRoot, `p09-deep-link-${kind}-events.json`, `deep-link-${kind}-events.json`, options.environmentId, `P-09 ${kind} deep-link events`);
    const events = parseJson(fs.readFileSync(path.join(repoRoot, eventLog.path)), `P-09 ${kind} deep-link events`);
    times.push(...events.events.map((event) => Date.parse(event.at)).filter(Number.isFinite));
    const uri = events.events[0]?.uri;
    const parsed = new URL(uri);
    return {
      kind, uri, selectedProviderId: parsed.searchParams.get('provider'),
      selectedModelId: kind === 'model' ? parsed.searchParams.get('model') : null,
      eventLog,
      atspi: copyRaw(repoRoot, shellRoot, inputRoot, `p09-deep-link-${kind}-atspi.json`, `deep-link-${kind}-atspi.json`, options.environmentId, `P-09 ${kind} deep-link AT-SPI`),
      screenshot: copyRaw(repoRoot, shellRoot, inputRoot, `p09-deep-link-${kind}.png`, `deep-link-${kind}.png`, options.environmentId, `P-09 ${kind} deep-link screenshot`)
    };
  });
  const windows = copyRaw(repoRoot, shellRoot, inputRoot, 'p09-native-window-events.json', 'native-window-events.json', options.environmentId, 'P-09 native window events');
  times.push(...timestampsFromJson(windows, repoRoot));
  for (const line of fs.readFileSync(path.join(repoRoot, perfSamples.path), 'utf8').split(/\n/u).filter(Boolean)) {
    const at = Date.parse(JSON.parse(line).at); if (Number.isFinite(at)) times.push(at);
  }
  if (times.length === 0) throw new Error('P-09 materializer found no live event timestamps');
  const document = {
    schemaVersion: 1, id: 'openburnbar-linux-p09-installed-session-v1', requirementId: 'P-09',
    environmentId: options.environmentId, targetHead: options.targetHead,
    candidate: { runId: String(options.candidateRunId), artifactDigest: options.candidateArtifactDigest },
    package: { architecture: expected.architecture, format: expected.format, installed: true, manifest, signature, source: 'verified-live-installed-candidate', version: options.packageVersion },
    desktop: { compositor: options.compositor, desktop: expected.desktop, displayServer: expected.session, liveSession: true },
    capture: { startedAt: new Date(Math.min(...times)).toISOString(), endedAt: new Date(Math.max(...times)).toISOString(), fixtureMode: false, method: 'installed-live-product-session' },
    navigation: { method: 'atspi-command-palette-actions', perfSamples, routes }, deepLinks, windows
  };
  const binding = { ...options, candidateRunId: String(options.candidateRunId) };
  validateP09InstalledSession(document, binding, { repoRoot });
  const output = path.join(inputRoot, P09_SESSION_FILENAME);
  fs.rmSync(output, { force: true });
  atomicWriteJson(output, document);
  return { document, output };
}

function args(argv) {
  const flags = ['--output-root', '--shell-evidence-dir', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256', '--manifest-signature-sha256', '--compositor'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!flags.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? '<missing>'}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return { outputRoot: values.get('--output-root'), shellEvidenceDir: values.get('--shell-evidence-dir'), environmentId: values.get('--environment'), targetHead: values.get('--target-head'), candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'), packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'), manifestSignatureSha256: values.get('--manifest-signature-sha256'), compositor: values.get('--compositor') };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify({ output: materializeP09NavigationShellSession(args(process.argv.slice(2))).output })}\n`); }
  catch (error) { process.stderr.write(`P-09 session materialization failed: ${error.message}\n`); process.exitCode = 1; }
}
