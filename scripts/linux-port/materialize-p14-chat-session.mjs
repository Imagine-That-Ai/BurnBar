#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { artifactRecord, atomicWriteJson, parseJson } from './lib/installed-ui-proof.mjs';
import { P14_SESSION_FILENAME, P14_SOURCE_CONTRACTS, validateP14InstalledSession } from './lib/p14-chat-proof.mjs';
import { INSTALLED_MANIFEST_PATH, INSTALLED_MANIFEST_SIGNATURE_PATH } from './lib/linux-installed-manifest.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const RAW_FILES = Object.freeze({
  daemon: 'daemon-chat-transcript.json',
  desktop: 'desktop-chat-transcript.json',
  databaseProbe: 'database-probe.json',
  databaseHeader: 'database-header.bin',
  attachment: 'attachment.bin',
  exportJson: 'chat-export.json',
  exportMarkdown: 'chat-export.md',
  windowEvents: 'window-events.json'
});

function copy(repoRoot, sourceRoot, outputRoot, sourceName, targetName, environmentId, label) {
  if (path.basename(sourceName) !== sourceName || path.basename(targetName) !== targetName) {
    throw new Error(`${label} name must be a basename`);
  }
  const source = path.join(sourceRoot, sourceName);
  const stat = fs.lstatSync(source);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${label} must be a regular non-symlink file`);
  const destination = path.join(outputRoot, 'raw', targetName);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  return artifactRecord(repoRoot, destination, 'P-14', environmentId, label);
}

function transcriptBounds(...documents) {
  const times = documents.flatMap((document) => (document.events ?? []).map((event) => Date.parse(event.at))).filter(Number.isFinite);
  if (!times.length) throw new Error('P-14 raw transcripts contain no timestamps');
  return { startedAt: new Date(Math.min(...times)).toISOString(), endedAt: new Date(Math.max(...times)).toISOString() };
}

export function materializeP14ChatSession(options, {
  installedVerifier = verifyInstalledCandidate,
  manifestPath = INSTALLED_MANIFEST_PATH,
  signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH
} = {}) {
  const repoRoot = fs.realpathSync(options.repoRoot ?? ROOT);
  const outputRoot = fs.realpathSync(options.outputRoot);
  const rawRoot = fs.realpathSync(options.rawEvidenceDir);
  const installed = installedVerifier(options);
  const manifest = copy(repoRoot, path.dirname(manifestPath), outputRoot, path.basename(manifestPath),
    'installed-manifest.json', options.environmentId, 'P-14 installed manifest');
  const signature = copy(repoRoot, path.dirname(signaturePath), outputRoot, path.basename(signaturePath),
    'installed-manifest.json.sig', options.environmentId, 'P-14 installed manifest signature');
  if (manifest.sha256 !== options.manifestSha256 || signature.sha256 !== options.manifestSignatureSha256) {
    throw new Error('P-14 installed attestation changed from the selected candidate');
  }
  const evidence = Object.fromEntries(Object.entries(RAW_FILES).map(([field, filename]) => [
    field,
    copy(repoRoot, rawRoot, outputRoot, filename, filename, options.environmentId, `P-14 ${field}`)
  ]));
  const daemon = parseJson(fs.readFileSync(path.join(repoRoot, evidence.daemon.path)), 'P-14 daemon transcript');
  const desktop = parseJson(fs.readFileSync(path.join(repoRoot, evidence.desktop.path)), 'P-14 desktop transcript');
  const expected = installed.contract;
  const document = {
    schemaVersion: 1,
    id: 'openburnbar-linux-p14-installed-chat-v1',
    requirementId: 'P-14',
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: { runId: String(options.candidateRunId), artifactDigest: options.candidateArtifactDigest },
    package: {
      architecture: expected.architecture,
      format: expected.format,
      installed: true,
      manifest,
      signature,
      source: 'verified-live-installed-candidate',
      version: options.packageVersion
    },
    desktop: {
      compositor: options.compositor,
      desktop: expected.desktop === 'gnome' ? 'GNOME' : expected.desktop === 'kde' ? 'KDE Plasma' : 'Sway/wlroots',
      displayServer: expected.session === 'x11' ? 'X11' : 'Wayland',
      liveSession: true
    },
    capture: { ...transcriptBounds(daemon, desktop), fixtureMode: false, method: 'installed-live-product-session' },
    threadID: options.threadID,
    sourceEvidence: P14_SOURCE_CONTRACTS.map((sourcePath) => {
      const snapshot = readRegularSnapshot(repoRoot, sourcePath, `P-14 source ${sourcePath}`);
      return { path: sourcePath, sha256: snapshot.sha256 };
    }),
    evidence
  };
  validateP14InstalledSession(document, { ...options, repoRoot, candidateRunId: String(options.candidateRunId) }, { repoRoot });
  const output = path.join(outputRoot, P14_SESSION_FILENAME);
  fs.rmSync(output, { force: true });
  atomicWriteJson(output, document);
  return { document, output };
}

export function parseP14MaterializeArguments(argv) {
  const flags = ['--output-root', '--raw-evidence-dir', '--environment', '--target-head', '--candidate-run-id',
    '--candidate-artifact-digest', '--package-version', '--manifest-sha256', '--manifest-signature-sha256',
    '--compositor', '--thread-id'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    if (!flags.includes(flag) || values.has(flag) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    values.set(flag, argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return { outputRoot: values.get('--output-root'), rawEvidenceDir: values.get('--raw-evidence-dir'),
    environmentId: values.get('--environment'), targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'),
    manifestSignatureSha256: values.get('--manifest-signature-sha256'), compositor: values.get('--compositor'),
    threadID: values.get('--thread-id') };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(materializeP14ChatSession(parseP14MaterializeArguments(process.argv.slice(2))))}\n`); }
  catch (error) { process.stderr.write(`P-14 materialization failed: ${error.message}\n`); process.exitCode = 1; }
}
