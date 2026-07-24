#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { artifactRecord, atomicWriteJson, INSTALLED_UI_ENVIRONMENTS, parseJson } from "./lib/installed-ui-proof.mjs";
import { INSTALLED_MANIFEST_PATH, INSTALLED_MANIFEST_SIGNATURE_PATH } from "./lib/linux-installed-manifest.mjs";
import { P33_RAW_FILES, P33_SESSION_FILENAME, P33_STATES, validateP33InstalledSession } from "./lib/p33-reliability-proof.mjs";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const COMPOSITOR = Object.freeze({ GNOME: "Mutter", "KDE Plasma": "KWin", "Sway/wlroots": "Sway" });

function directory(candidate, label, ownerOnly = false) {
  const absolute = path.resolve(candidate);
  const stat = fs.lstatSync(absolute);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid?.() || fs.realpathSync(absolute) !== absolute || (ownerOnly && (stat.mode & 0o077) !== 0)) throw new Error(`${label} must be a canonical owned${ownerOnly ? " owner-only" : ""} directory`);
  return absolute;
}
function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative !== "" && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}
function copy(repoRoot, sourceRoot, outputRoot, name, environmentId, label, ownerOnly = true) {
  if (path.basename(name) !== name) throw new Error(`${label} must be a basename`);
  const source = path.join(sourceRoot, name);
  const descriptor = fs.openSync(source, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
  let bytes;
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile() || stat.uid !== process.getuid?.() || (ownerOnly && (stat.mode & 0o077) !== 0) || (!ownerOnly && (stat.mode & 0o022) !== 0) || fs.realpathSync(path.dirname(source)) !== sourceRoot) throw new Error(`${label} is not a safe immutable artifact`);
    bytes = fs.readFileSync(descriptor);
  } finally { fs.closeSync(descriptor); }
  const destination = path.join(outputRoot, "raw", name);
  fs.writeFileSync(destination, bytes, { flag: "wx", mode: 0o600 });
  return artifactRecord(repoRoot, destination, "P-33", environmentId, label);
}

export function materializeP33ReliabilitySession(options, dependencies = {}) {
  const repoRoot = directory(options.repoRoot ?? ROOT, "P-33 repository");
  const outputRoot = directory(options.outputRoot, "P-33 output root");
  const rawRoot = directory(options.rawEvidenceDir, "P-33 raw evidence", true);
  if (!inside(repoRoot, outputRoot)) throw new Error("P-33 output root must be confined to the repository");
  if (rawRoot === outputRoot || inside(rawRoot, outputRoot) || inside(outputRoot, rawRoot)) throw new Error("P-33 raw and output roots must be disjoint");
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-33 requires a supported Linux environment");
  if (options.compositor !== COMPOSITOR[expected.desktop]) throw new Error("P-33 compositor does not match the live desktop");
  if (JSON.stringify(fs.readdirSync(rawRoot).sort()) !== JSON.stringify([...P33_RAW_FILES].sort())) throw new Error("P-33 raw evidence must contain exactly the native runner artifacts");
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  const copiedRoot = path.join(outputRoot, "raw");
  if (fs.existsSync(copiedRoot) || fs.lstatSync(copiedRoot, { throwIfNoEntry: false })) throw new Error("P-33 output evidence already exists; refusing replay");
  fs.mkdirSync(copiedRoot, { mode: 0o700 });
  const copied = Object.fromEntries(P33_RAW_FILES.map((name) => [name, copy(repoRoot, rawRoot, outputRoot, name, options.environmentId, `P-33 ${name}`)]));
  const manifestPath = dependencies.manifestPath ?? INSTALLED_MANIFEST_PATH;
  const signaturePath = dependencies.signaturePath ?? INSTALLED_MANIFEST_SIGNATURE_PATH;
  const manifest = copy(repoRoot, directory(path.dirname(manifestPath), "P-33 manifest directory"), outputRoot, path.basename(manifestPath), options.environmentId, "P-33 installed manifest", false);
  const signature = copy(repoRoot, directory(path.dirname(signaturePath), "P-33 signature directory"), outputRoot, path.basename(signaturePath), options.environmentId, "P-33 installed manifest signature", false);
  if (manifest.sha256 !== options.manifestSha256 || signature.sha256 !== options.manifestSignatureSha256) throw new Error("P-33 installed attestation changed during materialization");
  const marker = parseJson(fs.readFileSync(path.join(repoRoot, copied["reliability-marker.json"].path)), "P-33 marker");
  const native = parseJson(fs.readFileSync(path.join(repoRoot, copied["reliability-native-transcript.json"].path)), "P-33 transcript");
  const evidence = { marker: copied["reliability-marker.json"], nativeTranscript: copied["reliability-native-transcript.json"] };
  for (const state of P33_STATES) {
    evidence[`${state}Screenshot`] = copied[`reliability-${state}.png`];
    evidence[`${state}Accessibility`] = copied[`reliability-${state}-atspi.json`];
  }
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p33-installed-reliability-session-v1",
    requirementId: "P-33",
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: { runId: String(options.candidateRunId), artifactDigest: options.candidateArtifactDigest },
    package: { architecture: expected.architecture, format: expected.format, installed: true, manifest, signature, source: "verified-live-installed-candidate", version: options.packageVersion },
    desktop: { compositor: options.compositor, desktop: expected.desktop, displayServer: expected.session, liveSession: true },
    capture: { startedAt: native.startedAt, endedAt: native.endedAt, fixtureMode: false, method: "installed-live-product-session" },
    marker,
    evidence,
  };
  validateP33InstalledSession(document, { ...options, repoRoot, candidateRunId: String(options.candidateRunId) });
  const output = path.join(outputRoot, P33_SESSION_FILENAME);
  if (fs.existsSync(output) || fs.lstatSync(output, { throwIfNoEntry: false })) throw new Error("P-33 output session already exists; refusing replay");
  atomicWriteJson(output, document);
  return { document, output };
}

function parseArgs(argv) {
  const names = ["--output-root", "--raw-evidence-dir", "--environment", "--target-head", "--candidate-run-id", "--candidate-artifact-digest", "--package-version", "--manifest-sha256", "--manifest-signature-sha256", "--compositor"];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!names.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const name of names) if (!values.has(name)) throw new Error(`${name} is required`);
  return { outputRoot: values.get("--output-root"), rawEvidenceDir: values.get("--raw-evidence-dir"), environmentId: values.get("--environment"), targetHead: values.get("--target-head"), candidateRunId: values.get("--candidate-run-id"), candidateArtifactDigest: values.get("--candidate-artifact-digest"), packageVersion: values.get("--package-version"), manifestSha256: values.get("--manifest-sha256"), manifestSignatureSha256: values.get("--manifest-signature-sha256"), compositor: values.get("--compositor") };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(materializeP33ReliabilitySession(parseArgs(process.argv.slice(2))))}\n`); }
  catch (error) { process.stderr.write(`P-33 materialization failed: ${error.message}\n`); process.exitCode = 1; }
}
