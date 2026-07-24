#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  P32_REPORT_FILES,
  validateP32Invocation,
  validateP32RawReports,
} from "./lib/p32-performance-proof.mjs";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const BUDGET = path.join(ROOT, "budgets/linux-desktop.perf.json");
function head(root) {
  const result = spawnSync("git", ["rev-parse", "HEAD"], {
    cwd: root,
    encoding: "utf8",
  });
  if (result.status !== 0)
    throw new Error(
      `P-32 cannot resolve checkout HEAD: ${result.stderr.trim()}`,
    );
  return result.stdout.trim();
}

function assert(value, message) {
  if (!value) throw new Error(message);
}
function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}
function ownerOnlyDirectory(directory, label) {
  const absolute = path.resolve(directory);
  const stat = fs.lstatSync(absolute);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      fs.realpathSync(absolute) === absolute &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    `${label} must be a canonical owner-only directory`,
  );
  return absolute;
}
function readInput(directory, name) {
  const file = path.join(directory, name);
  assert(
    path.dirname(file) === directory,
    `P-32 ${name} is not a direct input child`,
  );
  const descriptor = fs.openSync(
    file,
    fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0),
  );
  try {
    const stat = fs.fstatSync(descriptor);
    assert(
      stat.isFile() &&
        stat.uid === process.getuid?.() &&
        (stat.mode & 0o077) === 0,
      `P-32 ${name} must be an owner-only regular file`,
    );
    return fs.readFileSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}
function writeExclusive(file, value) {
  const descriptor = fs.openSync(
    file,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
    0o600,
  );
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

export function runP32InstalledPerformanceWorkflow(
  options,
  {
    installedVerifier = verifyInstalledCandidate,
    resolveHead = head,
    now = () => new Date(),
    budget = JSON.parse(fs.readFileSync(BUDGET, "utf8")),
  } = {},
) {
  validateP32Invocation(options);
  assert(
    resolveHead(options.repoRoot ?? ROOT) === options.targetHead,
    "P-32 target HEAD does not match checkout HEAD",
  );
  const input = ownerOnlyDirectory(options.inputDir, "P-32 input directory");
  const output = ownerOnlyDirectory(options.outputDir, "P-32 output directory");
  assert(
    input !== output,
    "P-32 input and output directories must be distinct",
  );
  assert(
    fs.readdirSync(output).length === 0,
    "P-32 output directory must be empty",
  );
  const reports = Object.fromEntries(
    P32_REPORT_FILES.map((name) => [name, readInput(input, name)]),
  );
  const verified = validateP32RawReports(reports, budget, {
    ...options,
    repoRoot: options.repoRoot ?? ROOT,
  });
  const installed = installedVerifier(options);
  const architecture =
    installed?.contract?.architecture ?? verified.architecture;
  assert(
    architecture === verified.architecture,
    "P-32 installed and matched performance architectures differ",
  );
  const collectedAt = now();
  assert(
    Number.isFinite(collectedAt.getTime()) &&
      collectedAt.getTime() >= verified.productionWindow.newest &&
      collectedAt.getTime() - verified.productionWindow.newest <=
        2 * 60 * 60 * 1000 &&
      verified.productionWindow.newest - verified.productionWindow.oldest <=
        4 * 60 * 60 * 1000,
    "P-32 source reports are stale or not part of one bounded candidate run",
  );
  for (const name of P32_REPORT_FILES)
    fs.writeFileSync(path.join(output, name), reports[name], {
      flag: "wx",
      mode: 0o600,
    });
  const receipt = {
    producer: "openburnbar-p32-installed-performance-workflow-v1",
    fixtureMode: false,
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: {
      runId: String(options.candidateRunId),
      artifactDigest: options.candidateArtifactDigest,
    },
    package: {
      architecture,
      format: installed?.contract?.format ?? options.packageFormat,
      version: options.packageVersion,
      manifestSha256: options.manifestSha256,
      manifestSignatureSha256: options.manifestSignatureSha256,
    },
    reports: Object.fromEntries(
      P32_REPORT_FILES.map((name) => [name, hash(reports[name])]),
    ),
    verification: {
      architecture: verified.architecture,
      matchedWorkloadCount: verified.comparison.workloads.length,
      nativeMetricCount: verified.verdicts.length,
      profile: "nightly",
      runtimeSampleCount: verified.runtimeSampleCount,
      soakSeconds: budget.matched.profiles.nightly.soakSeconds,
      status: "passed",
    },
    collectedAt: collectedAt.toISOString(),
  };
  const receiptPath = path.join(output, "p32-native-performance-receipt.json");
  writeExclusive(receiptPath, receipt);
  return { outputDir: output, receipt, receiptPath };
}

function parseArguments(argv) {
  const flags = [
    "--input-dir",
    "--output-dir",
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
    inputDir: values.get("--input-dir"),
    outputDir: values.get("--output-dir"),
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
    const result = runP32InstalledPerformanceWorkflow(
      parseArguments(process.argv.slice(2)),
    );
    process.stdout.write(
      `${JSON.stringify({ receipt: result.receiptPath })}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-32 installed performance workflow failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
