#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { artifactRecord, atomicWriteJson } from "./lib/installed-ui-proof.mjs";
import {
  P32_PROOF_FILENAME,
  P32_PROOF_ROLE,
  buildP32Proof,
  validateP32InstalledSession,
  validateP32Invocation,
  validateP32Proof,
} from "./lib/p32-performance-proof.mjs";
import {
  readRegularSnapshot,
  SUPPORT_ENVIRONMENTS,
} from "./lib/product-proof-closure.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const BUDGET = path.join(ROOT, "budgets/linux-desktop.perf.json");
function head(root) {
  return spawnSync("git", ["rev-parse", "HEAD"], {
    cwd: root,
    encoding: "utf8",
  }).stdout.trim();
}
function confined(root, candidate, label) {
  const realRoot = fs.realpathSync(root);
  const absolute = fs.realpathSync(candidate);
  const relative = path.relative(realRoot, absolute);
  if (
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  )
    throw new Error(`${label} must remain inside the repository`);
  return { root: realRoot, absolute };
}

export function captureP32PerformanceProof(
  options,
  {
    resolveHead = head,
    now = () => new Date(),
    budget = JSON.parse(fs.readFileSync(BUDGET, "utf8")),
  } = {},
) {
  validateP32Invocation(options);
  if (!SUPPORT_ENVIRONMENTS.includes(options.environmentId))
    throw new Error("P-32 environment is unsupported");
  const input = confined(
    options.repoRoot ?? ROOT,
    options.inputRoot,
    "P-32 input root",
  );
  const report = confined(
    input.root,
    options.sessionReport,
    "P-32 session report",
  );
  if (resolveHead(input.root) !== options.targetHead)
    throw new Error("P-32 target HEAD does not match checkout HEAD");
  const source = artifactRecord(
    input.root,
    report.absolute,
    "P-32",
    options.environmentId,
    "P-32 session report",
  );
  const binding = {
    ...options,
    repoRoot: input.root,
    candidateRunId: String(options.candidateRunId),
    budget,
  };
  const session = validateP32InstalledSession(
    JSON.parse(fs.readFileSync(report.absolute, "utf8")),
    binding,
    { budget },
  );
  const proof = buildP32Proof({
    session: session.document,
    source,
    collectedAt: now().toISOString(),
  });
  const output = path.join(
    input.absolute,
    "feature-artifacts",
    P32_PROOF_FILENAME,
  );
  const registration = path.join(
    input.absolute,
    "feature-proof-registration.json",
  );
  fs.rmSync(output, { force: true });
  fs.rmSync(registration, { force: true });
  atomicWriteJson(output, proof);
  const record = artifactRecord(
    input.root,
    output,
    "P-32",
    options.environmentId,
    "P-32 proof",
  );
  validateP32Proof({
    ...binding,
    snapshot: readRegularSnapshot(input.root, record.path, "P-32 proof"),
  });
  atomicWriteJson(registration, {
    schemaVersion: 1,
    requirementId: "P-32",
    environmentId: options.environmentId,
    artifacts: [
      { role: P32_PROOF_ROLE, path: `feature-artifacts/${P32_PROOF_FILENAME}` },
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
    const result = captureP32PerformanceProof(
      parseArguments(process.argv.slice(2)),
    );
    process.stdout.write(
      `${JSON.stringify({ output: result.output, registration: result.registration })}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-32 performance proof capture failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
