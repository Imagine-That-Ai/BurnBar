#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { artifactRecord, atomicWriteJson, parseJson } from './lib/installed-ui-proof.mjs';
import { P11_SESSION_FILENAME, P11_SOURCE_CONTRACTS, validateP11InstalledSession } from './lib/p11-usage-ingestion-proof.mjs';
import { INSTALLED_MANIFEST_PATH, INSTALLED_MANIFEST_SIGNATURE_PATH } from './lib/linux-installed-manifest.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const RAW_FILES = Object.freeze({
  ledgerBefore: 'ledger-before.jsonl',
  ledgerAfterInsert: 'ledger-after-insert.jsonl',
  ledgerAfterDuplicate: 'ledger-after-duplicate.jsonl',
  ledgerAfterRestart: 'ledger-after-restart.jsonl',
  rpcTranscript: 'usage-rpc-transcript.json',
  malformedTranscript: 'usage-malformed-transcript.json',
  subscriptionTranscript: 'usage-subscription-transcript.json'
});

function copy(repoRoot, sourceRoot, outputRoot, sourceName, targetName, environmentId, label) {
  if (path.basename(sourceName) !== sourceName || path.basename(targetName) !== targetName) throw new Error(`${label} name must be a basename`);
  const source = path.join(sourceRoot, sourceName);
  const stat = fs.lstatSync(source);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${label} must be a regular non-symlink file`);
  const destination = path.join(outputRoot, 'raw', targetName);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  return artifactRecord(repoRoot, destination, 'P-11', environmentId, label);
}

function transcriptTimes(...documents) {
  const values = documents.flatMap((document) => (document.rows ?? []).flatMap((row) => [Date.parse(row.at), Date.parse(row.recovery?.at)])).filter(Number.isFinite);
  if (values.length === 0) throw new Error('P-11 raw transcripts contain no timestamps');
  return { startedAt: new Date(Math.min(...values)).toISOString(), endedAt: new Date(Math.max(...values)).toISOString() };
}

export function materializeP11UsageIngestionSession(options, {
  installedVerifier = verifyInstalledCandidate,
  manifestPath = INSTALLED_MANIFEST_PATH,
  signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH
} = {}) {
  const repoRoot = fs.realpathSync(options.repoRoot ?? DEFAULT_REPO_ROOT);
  const outputRoot = fs.realpathSync(options.outputRoot);
  const rawRoot = fs.realpathSync(options.rawEvidenceDir);
  const installed = installedVerifier(options);
  const manifest = copy(repoRoot, path.dirname(manifestPath), outputRoot, path.basename(manifestPath), 'installed-manifest.json', options.environmentId, 'P-11 installed manifest');
  const signature = copy(repoRoot, path.dirname(signaturePath), outputRoot, path.basename(signaturePath), 'installed-manifest.json.sig', options.environmentId, 'P-11 installed manifest signature');
  if (manifest.sha256 !== options.manifestSha256 || signature.sha256 !== options.manifestSignatureSha256) throw new Error('P-11 installed attestation changed from the selected candidate');
  const evidence = Object.fromEntries(Object.entries(RAW_FILES).map(([field, filename]) => [
    field,
    copy(repoRoot, rawRoot, outputRoot, filename, filename, options.environmentId, `P-11 ${field}`)
  ]));
  const rpc = parseJson(fs.readFileSync(path.join(repoRoot, evidence.rpcTranscript.path)), 'P-11 usage RPC transcript');
  const malformed = parseJson(fs.readFileSync(path.join(repoRoot, evidence.malformedTranscript.path)), 'P-11 malformed transcript');
  const subscription = parseJson(fs.readFileSync(path.join(repoRoot, evidence.subscriptionTranscript.path)), 'P-11 subscription transcript');
  const first = rpc.rows?.find((row) => row.phase === 'record-first');
  if (!first?.request?.params?.event || typeof first.request.params.idempotencyKey !== 'string') throw new Error('P-11 raw RPC transcript lacks the canonical ingestion request');
  const capture = transcriptTimes(rpc, malformed, subscription);
  const expected = installed.contract;
  const document = {
    schemaVersion: 1,
    id: 'openburnbar-linux-p11-installed-usage-ingestion-v1',
    requirementId: 'P-11',
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: { runId: String(options.candidateRunId), artifactDigest: options.candidateArtifactDigest },
    package: {
      architecture: expected.architecture, format: expected.format, installed: true,
      manifest, signature, source: 'verified-live-installed-candidate', version: options.packageVersion
    },
    desktop: {
      compositor: options.compositor, desktop: expected.desktop === 'gnome' ? 'GNOME' : expected.desktop === 'kde' ? 'KDE Plasma' : 'Sway/wlroots',
      displayServer: expected.session === 'x11' ? 'X11' : 'Wayland', liveSession: true
    },
    capture: { ...capture, fixtureMode: false, method: 'installed-live-product-session' },
    usage: { idempotencyKey: first.request.params.idempotencyKey, event: first.request.params.event },
    sourceEvidence: P11_SOURCE_CONTRACTS.map((sourcePath) => {
      const snapshot = readRegularSnapshot(repoRoot, sourcePath, `P-11 source ${sourcePath}`);
      return { path: sourcePath, sha256: snapshot.sha256 };
    }),
    evidence
  };
  validateP11InstalledSession(document, { ...options, repoRoot, candidateRunId: String(options.candidateRunId) }, { repoRoot });
  const output = path.join(outputRoot, P11_SESSION_FILENAME);
  fs.rmSync(output, { force: true });
  atomicWriteJson(output, document);
  return { document, output };
}

function args(argv) {
  const flags = ['--output-root', '--raw-evidence-dir', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256', '--manifest-signature-sha256', '--compositor'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!flags.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? '<missing>'}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    outputRoot: values.get('--output-root'), rawEvidenceDir: values.get('--raw-evidence-dir'), environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'), candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'), manifestSignatureSha256: values.get('--manifest-signature-sha256'),
    compositor: values.get('--compositor')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify({ output: materializeP11UsageIngestionSession(args(process.argv.slice(2))).output })}\n`); }
  catch (error) { process.stderr.write(`P-11 usage session materialization failed: ${error.message}\n`); process.exitCode = 1; }
}
