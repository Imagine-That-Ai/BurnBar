#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { artifactRecord, atomicWriteJson, INSTALLED_UI_ENVIRONMENTS, parseJson } from "./lib/installed-ui-proof.mjs";
import { P35_RAW_FILES, P35_SESSION_FILENAME, validateP35InstalledSession } from "./lib/p35-diagnostics-support-proof.mjs";
import { INSTALLED_MANIFEST_PATH, INSTALLED_MANIFEST_SIGNATURE_PATH } from "./lib/linux-installed-manifest.mjs";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function directory(candidate, label, ownerOnly = false) {
  const stat = fs.lstatSync(candidate);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid?.() || (ownerOnly && (stat.mode & 0o077) !== 0)) throw new Error(`${label} must be a real owned${ownerOnly ? " owner-only" : ""} directory`);
  return fs.realpathSync(candidate);
}
function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative !== "" && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}
function removeOwnedRegular(candidate, label) {
  if (!fs.existsSync(candidate)) return;
  const stat = fs.lstatSync(candidate);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid?.()) throw new Error(`${label} must be an owned regular file`);
  fs.rmSync(candidate);
}
function copy(repoRoot, sourceRoot, outputRoot, name, environmentId, label, ownerOnly = true) {
  const source = path.join(sourceRoot, name);
  const stat = fs.lstatSync(source);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid?.() || (ownerOnly && (stat.mode & 0o077) !== 0) || fs.realpathSync(path.dirname(source)) !== sourceRoot) throw new Error(`${label} is not a safe live artifact`);
  const destination = path.join(outputRoot, "raw", name);
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(destination, 0o600);
  return artifactRecord(repoRoot, destination, "P-35", environmentId, label);
}

export function materializeP35DiagnosticsSupportSession(options, dependencies = {}) {
  const repoRoot = directory(options.repoRoot ?? ROOT, "P-35 repository");
  const outputRoot = directory(options.outputRoot, "P-35 output root");
  const rawRoot = directory(options.rawEvidenceDir, "P-35 raw evidence", true);
  if (!inside(repoRoot, outputRoot)) throw new Error("P-35 output root must be confined to the repository");
  if (rawRoot === outputRoot || inside(rawRoot, outputRoot) || inside(outputRoot, rawRoot)) throw new Error("P-35 raw and output roots must be disjoint");
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-35 requires a supported Linux environment");
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  const copiedRoot = path.join(outputRoot, "raw");
  fs.mkdirSync(copiedRoot, { mode: 0o700 });
  const copied = Object.fromEntries(P35_RAW_FILES.map((name) => [name, copy(repoRoot, rawRoot, outputRoot, name, options.environmentId, `P-35 ${name}`)]));
  const manifestPath = dependencies.manifestPath ?? INSTALLED_MANIFEST_PATH;
  const signaturePath = dependencies.signaturePath ?? INSTALLED_MANIFEST_SIGNATURE_PATH;
  const manifest = copy(repoRoot, directory(path.dirname(manifestPath), "P-35 manifest directory"), outputRoot, path.basename(manifestPath), options.environmentId, "P-35 installed manifest", false);
  const signature = copy(repoRoot, directory(path.dirname(signaturePath), "P-35 signature directory"), outputRoot, path.basename(signaturePath), options.environmentId, "P-35 installed manifest signature", false);
  if (manifest.sha256 !== options.manifestSha256 || signature.sha256 !== options.manifestSignatureSha256) throw new Error("P-35 installed attestation changed during materialization");
  const marker = parseJson(fs.readFileSync(path.join(repoRoot, copied["diagnostics-marker.json"].path)), "P-35 marker");
  const native = parseJson(fs.readFileSync(path.join(repoRoot, copied["diagnostics-native-transcript.json"].path)), "P-35 transcript");
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p35-installed-diagnostics-support-session-v1",
    requirementId: "P-35",
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: { runId: String(options.candidateRunId), artifactDigest: options.candidateArtifactDigest },
    package: { architecture: expected.architecture, format: expected.format, installed: true, manifest, signature, source: "verified-live-installed-candidate", version: options.packageVersion },
    desktop: { compositor: options.compositor, desktop: expected.desktop, displayServer: expected.session, liveSession: true },
    capture: { startedAt: native.startedAt, endedAt: native.endedAt, fixtureMode: false, method: "installed-live-product-session" },
    marker,
    evidence: {
      nativeTranscript: copied["diagnostics-native-transcript.json"],
      exportBundle: copied["diagnostics-export.json"],
      previewScreenshot: copied["diagnostics-preview.png"],
      exportedScreenshot: copied["diagnostics-exported.png"],
      degradedScreenshot: copied["diagnostics-degraded.png"],
      recoveredScreenshot: copied["diagnostics-recovered.png"],
      previewAccessibility: copied["diagnostics-preview-atspi.json"],
      exportedAccessibility: copied["diagnostics-exported-atspi.json"],
      degradedAccessibility: copied["diagnostics-degraded-atspi.json"],
      recoveredAccessibility: copied["diagnostics-recovered-atspi.json"],
    },
  };
  validateP35InstalledSession(document, { ...options, repoRoot, candidateRunId: String(options.candidateRunId) });
  const output = path.join(outputRoot, P35_SESSION_FILENAME);
  removeOwnedRegular(output, "P-35 existing session report");
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
  try { process.stdout.write(`${JSON.stringify(materializeP35DiagnosticsSupportSession(parseArgs(process.argv.slice(2))))}\n`); }
  catch (error) { process.stderr.write(`P-35 materialization failed: ${error.message}\n`); process.exitCode = 1; }
}
