#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { artifactRecord, atomicWriteJson, DIGEST_PATTERN, HEAD_PATTERN, RUN_ID_PATTERN, SHA256_PATTERN, VERSION_PATTERN } from "./lib/installed-ui-proof.mjs";
import { buildP35Proof, P35_PROOF_FILENAME, P35_PROOF_ROLE, validateP35InstalledSession, validateP35Proof } from "./lib/p35-diagnostics-support-proof.mjs";
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from "./lib/product-proof-closure.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
function resolveHead(root) { return spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).stdout.trim(); }
function confined(root, candidate, label) {
  const realRoot = fs.realpathSync(root);
  const absolute = fs.realpathSync(candidate);
  const relative = path.relative(realRoot, absolute);
  if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) throw new Error(`${label} must remain inside the repository`);
  return { root: realRoot, absolute };
}
function removeOwnedRegular(candidate, label) {
  if (!fs.existsSync(candidate)) return;
  const stat = fs.lstatSync(candidate);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid?.()) throw new Error(`${label} must be an owned regular file`);
  fs.rmSync(candidate);
}

export function captureP35DiagnosticsSupportProof(options, dependencies = {}) {
  if (!SUPPORT_ENVIRONMENTS.includes(options.environmentId) || !HEAD_PATTERN.test(options.targetHead ?? "") || !RUN_ID_PATTERN.test(String(options.candidateRunId ?? "")) || !DIGEST_PATTERN.test(options.candidateArtifactDigest ?? "") || !VERSION_PATTERN.test(options.packageVersion ?? "") || !SHA256_PATTERN.test(options.manifestSha256 ?? "") || !SHA256_PATTERN.test(options.manifestSignatureSha256 ?? "")) throw new Error("P-35 invocation binding is invalid");
  const input = confined(options.repoRoot ?? ROOT, options.inputRoot, "P-35 input root");
  const report = confined(input.root, options.sessionReport, "P-35 session report");
  if ((dependencies.resolveHead ?? resolveHead)(input.root) !== options.targetHead) throw new Error("P-35 target HEAD does not match checkout HEAD");
  const source = artifactRecord(input.root, report.absolute, "P-35", options.environmentId, "P-35 session report");
  const binding = { ...options, repoRoot: input.root, candidateRunId: String(options.candidateRunId) };
  const validated = validateP35InstalledSession(JSON.parse(fs.readFileSync(report.absolute, "utf8")), binding);
  const proof = buildP35Proof({ session: validated.document, source, collectedAt: (dependencies.now?.() ?? new Date()).toISOString() });
  const output = path.join(input.absolute, "feature-artifacts", P35_PROOF_FILENAME);
  const registration = path.join(input.absolute, "feature-proof-registration.json");
  removeOwnedRegular(output, "P-35 existing proof");
  removeOwnedRegular(registration, "P-35 existing registration");
  atomicWriteJson(output, proof);
  const record = artifactRecord(input.root, output, "P-35", options.environmentId, "P-35 proof");
  validateP35Proof({ ...binding, snapshot: readRegularSnapshot(input.root, record.path, "P-35 proof") });
  atomicWriteJson(registration, { schemaVersion: 1, requirementId: "P-35", environmentId: options.environmentId, artifacts: [{ role: P35_PROOF_ROLE, path: `feature-artifacts/${P35_PROOF_FILENAME}` }] });
  return { output, registration, document: proof };
}

function parseArgs(argv) {
  const names = ["--input-root", "--session-report", "--environment", "--target-head", "--candidate-run-id", "--candidate-artifact-digest", "--package-version", "--manifest-sha256", "--manifest-signature-sha256"];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!names.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const name of names) if (!values.has(name)) throw new Error(`${name} is required`);
  return { inputRoot: values.get("--input-root"), sessionReport: values.get("--session-report"), environmentId: values.get("--environment"), targetHead: values.get("--target-head"), candidateRunId: values.get("--candidate-run-id"), candidateArtifactDigest: values.get("--candidate-artifact-digest"), packageVersion: values.get("--package-version"), manifestSha256: values.get("--manifest-sha256"), manifestSignatureSha256: values.get("--manifest-signature-sha256") };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(captureP35DiagnosticsSupportProof(parseArgs(process.argv.slice(2))))}\n`); }
  catch (error) { process.stderr.write(`P-35 proof capture failed: ${error.message}\n`); process.exitCode = 1; }
}
