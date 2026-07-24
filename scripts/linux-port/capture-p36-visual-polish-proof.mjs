#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  artifactRecord,
  atomicWriteJson,
  DIGEST_PATTERN,
  HEAD_PATTERN,
  RUN_ID_PATTERN,
  SHA256_PATTERN,
  VERSION_PATTERN,
} from "./lib/installed-ui-proof.mjs";
import {
  buildP36Proof,
  P36_PROOF_FILENAME,
  P36_PROOF_ROLE,
  validateP36InstalledSession,
  validateP36Proof,
} from "./lib/p36-visual-polish-proof.mjs";
import {
  readRegularSnapshot,
  SUPPORT_ENVIRONMENTS,
} from "./lib/product-proof-closure.mjs";
const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
function head(root) {
  return spawnSync("git", ["rev-parse", "HEAD"], {
    cwd: root,
    encoding: "utf8",
  }).stdout.trim();
}
function confined(root, candidate, label, type) {
  const realRoot = fs.realpathSync(root);
  const requested = path.resolve(candidate);
  const stat = fs.lstatSync(requested);
  if (
    stat.isSymbolicLink() ||
    stat.uid !== process.getuid?.() ||
    (type === "file" ? !stat.isFile() : !stat.isDirectory())
  )
    throw new Error(`${label} must be an owned real ${type}`);
  const absolute = fs.realpathSync(requested);
  const relative = path.relative(realRoot, absolute);
  if (
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  )
    throw new Error(`${label} must remain inside repository`);
  return { root: realRoot, absolute };
}
export function captureP36VisualPolishProof(options, dependencies = {}) {
  if (
    !SUPPORT_ENVIRONMENTS.includes(options.environmentId) ||
    !HEAD_PATTERN.test(options.targetHead ?? "") ||
    !RUN_ID_PATTERN.test(String(options.candidateRunId ?? "")) ||
    !DIGEST_PATTERN.test(options.candidateArtifactDigest ?? "") ||
    !VERSION_PATTERN.test(options.packageVersion ?? "") ||
    !SHA256_PATTERN.test(options.manifestSha256 ?? "") ||
    !SHA256_PATTERN.test(options.manifestSignatureSha256 ?? "")
  )
    throw new Error("P-36 invocation binding invalid");
  const input = confined(
    options.repoRoot ?? ROOT,
    options.inputRoot,
    "P-36 input root",
    "directory",
  );
  const report = confined(
    input.root,
    options.sessionReport,
    "P-36 session report",
    "file",
  );
  const reportRelative = path.relative(input.absolute, report.absolute);
  if (
    reportRelative === ".." ||
    reportRelative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(reportRelative)
  )
    throw new Error("P-36 session report must remain inside the input root");
  if ((dependencies.resolveHead ?? head)(input.root) !== options.targetHead)
    throw new Error("P-36 HEAD mismatch");
  const source = artifactRecord(
    input.root,
    report.absolute,
    "P-36",
    options.environmentId,
    "P-36 session report",
  );
  const binding = {
    ...options,
    repoRoot: input.root,
    candidateRunId: String(options.candidateRunId),
  };
  const validated = validateP36InstalledSession(
    JSON.parse(fs.readFileSync(report.absolute, "utf8")),
    binding,
  );
  const proof = buildP36Proof({
    session: validated.document,
    source,
    collectedAt: (dependencies.now?.() ?? new Date()).toISOString(),
  });
  const output = path.join(
    input.absolute,
    "feature-artifacts",
    P36_PROOF_FILENAME,
  );
  const registration = path.join(
    input.absolute,
    "feature-proof-registration.json",
  );
  for (const file of [output, registration])
    if (fs.existsSync(file))
      throw new Error(
        `P-36 capture refuses to replace existing output: ${file}`,
      );
  atomicWriteJson(output, proof);
  const record = artifactRecord(
    input.root,
    output,
    "P-36",
    options.environmentId,
    "P-36 proof",
  );
  validateP36Proof({
    ...binding,
    snapshot: readRegularSnapshot(input.root, record.path, "P-36 proof"),
  });
  atomicWriteJson(registration, {
    schemaVersion: 1,
    requirementId: "P-36",
    environmentId: options.environmentId,
    artifacts: [
      { role: P36_PROOF_ROLE, path: `feature-artifacts/${P36_PROOF_FILENAME}` },
    ],
  });
  return { output, registration, document: proof };
}
function parseArgs(argv) {
  const names = [
    "--input-root",
    "--session-report",
    "--environment",
    "--target-head",
    "--candidate-run-id",
    "--candidate-artifact-digest",
    "--package-version",
    "--manifest-sha256",
    "--manifest-signature-sha256",
  ];
  const values = new Map();
  for (let i = 0; i < argv.length; i += 2) {
    if (
      !names.includes(argv[i]) ||
      values.has(argv[i]) ||
      argv[i + 1] === undefined
    )
      throw new Error(`invalid argument: ${argv[i] ?? "<missing>"}`);
    values.set(argv[i], argv[i + 1]);
  }
  for (const name of names)
    if (!values.has(name)) throw new Error(`${name} required`);
  return {
    inputRoot: values.get("--input-root"),
    sessionReport: values.get("--session-report"),
    environmentId: values.get("--environment"),
    targetHead: values.get("--target-head"),
    candidateRunId: values.get("--candidate-run-id"),
    candidateArtifactDigest: values.get("--candidate-artifact-digest"),
    packageVersion: values.get("--package-version"),
    manifestSha256: values.get("--manifest-sha256"),
    manifestSignatureSha256: values.get("--manifest-signature-sha256"),
  };
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    process.stdout.write(
      `${JSON.stringify(captureP36VisualPolishProof(parseArgs(process.argv.slice(2))))}\n`,
    );
  } catch (error) {
    process.stderr.write(`P-36 capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
