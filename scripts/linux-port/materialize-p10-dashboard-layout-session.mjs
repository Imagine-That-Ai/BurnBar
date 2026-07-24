#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  INSTALLED_UI_ENVIRONMENTS,
  artifactRecord,
  atomicWriteJson,
  exactKeys,
  parseJson,
  validatePng
} from './lib/installed-ui-proof.mjs';
import {
  P10_LAYOUTS,
  P10_SESSION_FILENAME,
  P10_VIEWPORTS,
  validateP10InstalledSession
} from './lib/p10-dashboard-layout-proof.mjs';
import { INSTALLED_MANIFEST_PATH, INSTALLED_MANIFEST_SIGNATURE_PATH } from './lib/linux-installed-manifest.mjs';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function copyRaw(repoRoot, sourceRoot, inputRoot, sourceName, targetName, environmentId, label) {
  if (path.basename(sourceName) !== sourceName || path.basename(targetName) !== targetName) throw new Error(`${label} name must be a basename`);
  const source = path.join(sourceRoot, sourceName);
  const stat = fs.lstatSync(source);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${label} source must be a regular non-symlink file`);
  const destination = path.join(inputRoot, 'raw', targetName);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  return artifactRecord(repoRoot, destination, 'P-10', environmentId, label);
}

export function materializeP10DashboardLayoutSession(options, {
  installedVerifier = verifyInstalledCandidate,
  manifestPath = INSTALLED_MANIFEST_PATH,
  signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH
} = {}) {
  const repoRoot = fs.realpathSync(options.repoRoot ?? DEFAULT_REPO_ROOT);
  const inputRoot = fs.realpathSync(options.outputRoot);
  const rawRoot = fs.realpathSync(options.rawEvidenceDir);
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error('P-10 materializer requires a supported environment');
  installedVerifier(options);
  if (!options.compositor || /(?:xvfb|xfce|synthetic|mock)/iu.test(options.compositor)) {
    throw new Error('P-10 materializer requires the real compositor identity');
  }
  const manifest = copyRaw(repoRoot, path.dirname(manifestPath), inputRoot, path.basename(manifestPath), 'installed-manifest.json', options.environmentId, 'P-10 installed manifest');
  const signature = copyRaw(repoRoot, path.dirname(signaturePath), inputRoot, path.basename(signaturePath), 'installed-manifest.json.sig', options.environmentId, 'P-10 installed manifest signature');
  if (manifest.sha256 !== options.manifestSha256 || signature.sha256 !== options.manifestSignatureSha256) {
    throw new Error('P-10 installed attestation copy changed from the selected candidate');
  }
  const captures = [];
  const times = [];
  for (const layout of P10_LAYOUTS) for (const viewport of P10_VIEWPORTS) {
    const key = `${layout}-${viewport}`;
    const events = copyRaw(repoRoot, rawRoot, inputRoot, `layout-${key}-events.json`, `layout-${key}-events.json`, options.environmentId, `P-10 ${key} events`);
    const eventDocument = parseJson(fs.readFileSync(path.join(repoRoot, events.path)), `P-10 ${key} events`);
    times.push(...(eventDocument.events ?? []).map((event) => Date.parse(event.at)).filter(Number.isFinite));
    const daemon = copyRaw(repoRoot, rawRoot, inputRoot, `layout-${key}-daemon.json`, `layout-${key}-daemon.json`, options.environmentId, `P-10 ${key} daemon`);
    const screenshot = copyRaw(repoRoot, rawRoot, inputRoot, `layout-${key}.png`, `layout-${key}.png`, options.environmentId, `P-10 ${key} screenshot`);
    const image = validatePng(fs.readFileSync(path.join(repoRoot, screenshot.path)), `P-10 ${key} screenshot`);
    const atspi = copyRaw(repoRoot, rawRoot, inputRoot, `layout-${key}-atspi.json`, `layout-${key}-atspi.json`, options.environmentId, `P-10 ${key} AT-SPI`);
    const geometryRecord = copyRaw(repoRoot, rawRoot, inputRoot, `layout-${key}-geometry.json`, `layout-${key}-geometry.json`, options.environmentId, `P-10 ${key} geometry`);
    const geometry = parseJson(fs.readFileSync(path.join(repoRoot, geometryRecord.path)), `P-10 ${key} geometry`);
    exactKeys(geometry, ['capturedAt', 'clippedElements', 'nodesInspected', 'overlaps', 'producer', 'sourceAtspiSha256', 'textOverflow', 'unreadableText'], `P-10 ${key} geometry`);
    if (geometry.producer !== 'openburnbar-p10-live-geometry-probe-v1' || geometry.sourceAtspiSha256 !== atspi.sha256
        || !Number.isSafeInteger(geometry.nodesInspected) || geometry.nodesInspected < 1) {
      throw new Error(`P-10 ${key} geometry is not live-AT-SPI-bound`);
    }
    for (const field of ['clippedElements', 'overlaps', 'textOverflow', 'unreadableText']) {
      if (!Array.isArray(geometry[field])) throw new Error(`P-10 ${key} geometry ${field} must be an array`);
    }
    const pixelAuditPath = path.join(inputRoot, 'raw', `layout-${key}-pixel-audit.json`);
    atomicWriteJson(pixelAuditPath, {
      producer: 'openburnbar-p10-materializer-v1', screenshotSha256: screenshot.sha256,
      geometrySha256: geometryRecord.sha256, width: image.width, height: image.height,
      nonBlankPixelRatio: Number(image.nonBlankPixelRatio.toFixed(6)),
      clippedElementCount: geometry.clippedElements.length, overlapFindingCount: geometry.overlaps.length,
      textOverflowCount: geometry.textOverflow.length, unreadableTextCount: geometry.unreadableText.length
    });
    captures.push({
      layout, viewport, renderBackend: options.renderBackend, events, daemon, screenshot, atspi,
      geometry: geometryRecord,
      pixelAudit: artifactRecord(repoRoot, pixelAuditPath, 'P-10', options.environmentId, `P-10 ${key} pixel audit`)
    });
  }
  if (!options.renderBackend || /(?:placeholder|fixture|mock|storybook)/iu.test(options.renderBackend)) {
    throw new Error('P-10 materializer requires the installed renderer identity');
  }
  const stateEventLog = copyRaw(repoRoot, rawRoot, inputRoot, 'dashboard-state-events.json', 'dashboard-state-events.json', options.environmentId, 'P-10 dashboard state events');
  const stateEvents = parseJson(fs.readFileSync(path.join(repoRoot, stateEventLog.path)), 'P-10 dashboard state events');
  times.push(...(stateEvents.events ?? []).map((event) => Date.parse(event.at)).filter(Number.isFinite));
  const stateOrder = ['loading', 'populated', 'offline', 'error'];
  const stateSnapshots = stateOrder.map((state) => ({
    state,
    atspi: copyRaw(repoRoot, rawRoot, inputRoot, `dashboard-state-${state}-atspi.json`, `dashboard-state-${state}-atspi.json`, options.environmentId, `P-10 ${state} state AT-SPI`)
  }));
  if (times.length === 0) throw new Error('P-10 materializer found no live event timestamps');
  const document = {
    schemaVersion: 1, id: 'openburnbar-linux-p10-installed-session-v1', requirementId: 'P-10',
    environmentId: options.environmentId, targetHead: options.targetHead,
    candidate: { runId: String(options.candidateRunId), artifactDigest: options.candidateArtifactDigest },
    package: { architecture: expected.architecture, format: expected.format, installed: true, manifest, signature, source: 'verified-live-installed-candidate', version: options.packageVersion },
    desktop: { compositor: options.compositor, desktop: expected.desktop, displayServer: expected.session, liveSession: true },
    capture: { startedAt: new Date(Math.min(...times)).toISOString(), endedAt: new Date(Math.max(...times)).toISOString(), fixtureMode: false, method: 'installed-live-product-session' },
    captures, states: { eventLog: stateEventLog, snapshots: stateSnapshots }
  };
  validateP10InstalledSession(document, { ...options, candidateRunId: String(options.candidateRunId) }, { repoRoot });
  const output = path.join(inputRoot, P10_SESSION_FILENAME);
  fs.rmSync(output, { force: true });
  atomicWriteJson(output, document);
  return { document, output };
}

function args(argv) {
  const flags = ['--output-root', '--raw-evidence-dir', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256', '--manifest-signature-sha256', '--compositor', '--render-backend'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!flags.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? '<missing>'}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return { outputRoot: values.get('--output-root'), rawEvidenceDir: values.get('--raw-evidence-dir'), environmentId: values.get('--environment'), targetHead: values.get('--target-head'), candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'), packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'), manifestSignatureSha256: values.get('--manifest-signature-sha256'), compositor: values.get('--compositor'), renderBackend: values.get('--render-backend') };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify({ output: materializeP10DashboardLayoutSession(args(process.argv.slice(2))).output })}\n`); }
  catch (error) { process.stderr.write(`P-10 session materialization failed: ${error.message}\n`); process.exitCode = 1; }
}
