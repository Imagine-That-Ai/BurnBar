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
  buildP16Proof,
  P16_PROOF_FILENAME,
  P16_PROOF_ROLE,
  validateP16InstalledSession,
  validateP16Proof,
} from "./lib/p16-cloud-devices-proof.mjs";
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
function confined(root, candidate, label) {
  const realRoot = fs.realpathSync(root);
  const requested = path.resolve(candidate);
  const stat = fs.lstatSync(requested);
  if (
    !stat.isFile() ||
    stat.isSymbolicLink() ||
    stat.uid !== process.getuid?.()
  )
    throw new Error(`${label} must be an owned regular file`);
  const absolute = fs.realpathSync(requested);
  const relative = path.relative(realRoot, absolute);
  if (
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  )
    throw new Error(`${label} must remain inside the repository`);
  return { root: realRoot, absolute };
}
function validateInvocation(options) {
  if (
    !SUPPORT_ENVIRONMENTS.includes(options.environmentId) ||
    !HEAD_PATTERN.test(options.targetHead ?? "") ||
    !RUN_ID_PATTERN.test(String(options.candidateRunId ?? "")) ||
    !DIGEST_PATTERN.test(options.candidateArtifactDigest ?? "") ||
    !VERSION_PATTERN.test(options.packageVersion ?? "") ||
    !SHA256_PATTERN.test(options.manifestSha256 ?? "") ||
    !SHA256_PATTERN.test(options.manifestSignatureSha256 ?? "")
  )
    throw new Error("P-16 invocation binding is invalid");
}

export function captureP16CloudDevicesProof(
  options,
  { resolveHead = head, now = () => new Date() } = {},
) {
  validateInvocation(options);
  const requestedInput = path.resolve(options.inputRoot);
  const inputStat = fs.lstatSync(requestedInput);
  if (
    !inputStat.isDirectory() ||
    inputStat.isSymbolicLink() ||
    inputStat.uid !== process.getuid?.()
  )
    throw new Error("P-16 input root must be an owned real directory");
  const input = fs.realpathSync(requestedInput);
  const root = fs.realpathSync(options.repoRoot ?? ROOT);
  const relative = path.relative(root, input);
  if (
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  )
    throw new Error("P-16 input root must remain inside the repository");
  const report = confined(root, options.sessionReport, "P-16 session report");
  if (resolveHead(root) !== options.targetHead)
    throw new Error("P-16 target HEAD does not match checkout HEAD");
  const source = artifactRecord(
    root,
    report.absolute,
    "P-16",
    options.environmentId,
    "P-16 session report",
  );
  const binding = {
    ...options,
    repoRoot: root,
    candidateRunId: String(options.candidateRunId),
  };
  const validated = validateP16InstalledSession(
    JSON.parse(fs.readFileSync(report.absolute, "utf8")),
    binding,
  );
  const proof = buildP16Proof({
    session: validated.document,
    source,
    collectedAt: now().toISOString(),
  });
  const output = path.join(input, "feature-artifacts", P16_PROOF_FILENAME);
  const registration = path.join(input, "feature-proof-registration.json");
  for (const file of [output, registration])
    if (fs.existsSync(file))
      throw new Error(
        `P-16 capture refuses to replace existing output: ${file}`,
      );
  atomicWriteJson(output, proof);
  const record = artifactRecord(
    root,
    output,
    "P-16",
    options.environmentId,
    "P-16 proof",
  );
  validateP16Proof({
    ...binding,
    snapshot: readRegularSnapshot(root, record.path, "P-16 proof"),
  });
  atomicWriteJson(registration, {
    schemaVersion: 1,
    requirementId: "P-16",
    environmentId: options.environmentId,
    artifacts: [
      {
        role: P16_PROOF_ROLE,
        path: `feature-artifacts/${P16_PROOF_FILENAME}`,
      },
    ],
  });
  return { document: proof, output, registration };
}

function parseArguments(argv) {
  const flags = [
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
  for (let index = 0; index < argv.length; index += 2) {
    if (
      !flags.includes(argv[index]) ||
      values.has(argv[index]) ||
      argv[index + 1] === undefined
    )
      throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags)
    if (!values.has(flag)) throw new Error(`${flag} is required`);
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
    const result = captureP16CloudDevicesProof(
      parseArguments(process.argv.slice(2)),
    );
    process.stdout.write(
      `${JSON.stringify({ output: result.output, registration: result.registration })}\n`,
    );
  } catch (error) {
    process.stderr.write(`P-16 proof capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
