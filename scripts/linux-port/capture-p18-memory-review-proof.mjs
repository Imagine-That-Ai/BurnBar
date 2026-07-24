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
  P18_PROOF_FILENAME,
  P18_PROOF_ROLE,
  buildP18Proof,
  validateP18InstalledSession,
  validateP18Proof,
} from "./lib/p18-memory-review-proof.mjs";
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
function inside(root, candidate, label) {
  const realRoot = fs.realpathSync(root);
  const absolute = fs.realpathSync(candidate);
  const relative = path.relative(realRoot, absolute);
  if (
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  ) {
    throw new Error(`${label} must remain inside the repository`);
  }
  return { root: realRoot, absolute };
}

export function captureP18MemoryReviewProof(
  options,
  { resolveHead = head, now = () => new Date() } = {},
) {
  if (
    !SUPPORT_ENVIRONMENTS.includes(options.environmentId) ||
    !HEAD_PATTERN.test(options.targetHead ?? "") ||
    !RUN_ID_PATTERN.test(String(options.candidateRunId ?? "")) ||
    !DIGEST_PATTERN.test(options.candidateArtifactDigest ?? "") ||
    !VERSION_PATTERN.test(options.packageVersion ?? "") ||
    !SHA256_PATTERN.test(options.manifestSha256 ?? "") ||
    !SHA256_PATTERN.test(options.manifestSignatureSha256 ?? "")
  )
    throw new Error("P-18 invocation binding is invalid");
  const rootInfo = inside(
    options.repoRoot ?? ROOT,
    options.inputRoot,
    "P-18 input root",
  );
  const reportInfo = inside(
    rootInfo.root,
    options.sessionReport,
    "P-18 session report",
  );
  if (resolveHead(rootInfo.root) !== options.targetHead)
    throw new Error("P-18 target HEAD does not match checkout HEAD");
  const source = artifactRecord(
    rootInfo.root,
    reportInfo.absolute,
    "P-18",
    options.environmentId,
    "P-18 session report",
  );
  const binding = {
    ...options,
    repoRoot: rootInfo.root,
    candidateRunId: String(options.candidateRunId),
  };
  const validated = validateP18InstalledSession(
    JSON.parse(fs.readFileSync(reportInfo.absolute, "utf8")),
    binding,
    { repoRoot: rootInfo.root },
  );
  const proof = buildP18Proof({
    session: validated.document,
    source,
    collectedAt: now().toISOString(),
    events: validated.events,
    auditEvents: validated.auditEvents,
  });
  const output = path.join(
    rootInfo.absolute,
    "feature-artifacts",
    P18_PROOF_FILENAME,
  );
  const registration = path.join(
    rootInfo.absolute,
    "feature-proof-registration.json",
  );
  fs.rmSync(output, { force: true });
  fs.rmSync(registration, { force: true });
  atomicWriteJson(output, proof);
  const record = artifactRecord(
    rootInfo.root,
    output,
    "P-18",
    options.environmentId,
    "P-18 proof",
  );
  validateP18Proof({
    ...binding,
    snapshot: readRegularSnapshot(rootInfo.root, record.path, "P-18 proof"),
  });
  atomicWriteJson(registration, {
    schemaVersion: 1,
    requirementId: "P-18",
    environmentId: options.environmentId,
    artifacts: [
      { role: P18_PROOF_ROLE, path: `feature-artifacts/${P18_PROOF_FILENAME}` },
    ],
  });
  return { output, registration, document: proof };
}

function args(argv) {
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
    const result = captureP18MemoryReviewProof(args(process.argv.slice(2)));
    process.stdout.write(
      `${JSON.stringify({ output: result.output, registration: result.registration })}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-18 memory-review proof capture failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
