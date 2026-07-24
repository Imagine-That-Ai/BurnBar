#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { artifactRecord, atomicWriteJson, DIGEST_PATTERN, HEAD_PATTERN, RUN_ID_PATTERN, SHA256_PATTERN, VERSION_PATTERN } from "./lib/installed-ui-proof.mjs";
import { buildP33Proof, P33_PROOF_FILENAME, P33_PROOF_ROLE, validateP33InstalledSession, validateP33Proof } from "./lib/p33-reliability-proof.mjs";
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from "./lib/product-proof-closure.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
function head(root) { return spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).stdout.trim(); }
function confined(root, candidate, label, directory = false) {
  const realRoot = fs.realpathSync(root);
  const requested = path.resolve(candidate);
  const stat = fs.lstatSync(requested);
  if ((directory ? !stat.isDirectory() : !stat.isFile()) || stat.isSymbolicLink() || stat.uid !== process.getuid?.()) throw new Error(`${label} must be an owned real ${directory ? "directory" : "file"}`);
  const absolute = fs.realpathSync(requested);
  const relative = path.relative(realRoot, absolute);
  if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) throw new Error(`${label} must remain inside the repository`);
  return { root: realRoot, absolute };
}

export function captureP33ReliabilityProof(options, dependencies = {}) {
  if (!SUPPORT_ENVIRONMENTS.includes(options.environmentId) || !HEAD_PATTERN.test(options.targetHead ?? "") || !RUN_ID_PATTERN.test(String(options.candidateRunId ?? "")) || !DIGEST_PATTERN.test(options.candidateArtifactDigest ?? "") || !VERSION_PATTERN.test(options.packageVersion ?? "") || !SHA256_PATTERN.test(options.manifestSha256 ?? "") || !SHA256_PATTERN.test(options.manifestSignatureSha256 ?? "")) throw new Error("P-33 invocation binding is invalid");
  const input = confined(options.repoRoot ?? ROOT, options.inputRoot, "P-33 input root", true);
  const report = confined(input.root, options.sessionReport, "P-33 session report");
  if ((dependencies.resolveHead ?? head)(input.root) !== options.targetHead) throw new Error("P-33 target HEAD does not match checkout HEAD");
  const source = artifactRecord(input.root, report.absolute, "P-33", options.environmentId, "P-33 session report");
  const binding = { ...options, repoRoot: input.root, candidateRunId: String(options.candidateRunId) };
  const validated = validateP33InstalledSession(JSON.parse(fs.readFileSync(report.absolute, "utf8")), binding);
  const proof = buildP33Proof({ session: validated.document, source, collectedAt: (dependencies.now?.() ?? new Date()).toISOString() });
  const output = path.join(input.absolute, "feature-artifacts", P33_PROOF_FILENAME);
  const registration = path.join(input.absolute, "feature-proof-registration.json");
  for (const file of [output, registration]) if (fs.existsSync(file) || fs.lstatSync(file, { throwIfNoEntry: false })) throw new Error(`P-33 capture refuses to replace existing output: ${file}`);
  atomicWriteJson(output, proof);
  const record = artifactRecord(input.root, output, "P-33", options.environmentId, "P-33 proof");
  validateP33Proof({ ...binding, snapshot: readRegularSnapshot(input.root, record.path, "P-33 proof") });
  atomicWriteJson(registration, { schemaVersion: 1, requirementId: "P-33", environmentId: options.environmentId, artifacts: [{ role: P33_PROOF_ROLE, path: `feature-artifacts/${P33_PROOF_FILENAME}` }] });
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
  try { process.stdout.write(`${JSON.stringify(captureP33ReliabilityProof(parseArgs(process.argv.slice(2))))}\n`); }
  catch (error) { process.stderr.write(`P-33 proof capture failed: ${error.message}\n`); process.exitCode = 1; }
}
