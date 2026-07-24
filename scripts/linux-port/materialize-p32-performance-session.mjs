#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  artifactRecord,
  atomicWriteJson,
  INSTALLED_UI_ENVIRONMENTS,
  parseJson,
} from "./lib/installed-ui-proof.mjs";
import {
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH,
} from "./lib/linux-installed-manifest.mjs";
import {
  P32_RAW_FILES,
  P32_SESSION_FILENAME,
  validateP32InstalledSession,
  validateP32Invocation,
} from "./lib/p32-performance-proof.mjs";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const BUDGET = path.join(ROOT, "budgets/linux-desktop.perf.json");

function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return (
    relative !== "" &&
    relative !== ".." &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}
function directory(value, label, ownerOnly = false) {
  const absolute = path.resolve(value);
  const stat = fs.lstatSync(absolute);
  if (
    !stat.isDirectory() ||
    stat.isSymbolicLink() ||
    fs.realpathSync(absolute) !== absolute ||
    stat.uid !== process.getuid?.() ||
    (ownerOnly && (stat.mode & 0o077) !== 0)
  )
    throw new Error(
      `${label} must be a canonical ${ownerOnly ? "owner-only " : ""}directory`,
    );
  return absolute;
}
function copy(
  repoRoot,
  sourceRoot,
  outputRoot,
  name,
  environmentId,
  label,
  ownerOnly,
) {
  if (path.basename(name) !== name)
    throw new Error(`${label} must be a basename`);
  const source = path.join(sourceRoot, name);
  if (!inside(sourceRoot, source) || fs.realpathSync(source) !== source)
    throw new Error(`${label} escapes its canonical source directory`);
  const descriptor = fs.openSync(
    source,
    fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0),
  );
  let bytes;
  try {
    const stat = fs.fstatSync(descriptor);
    if (
      !stat.isFile() ||
      (ownerOnly &&
        (stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0)) ||
      (!ownerOnly && (stat.mode & 0o022) !== 0)
    )
      throw new Error(`${label} is not an immutable regular file`);
    bytes = fs.readFileSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  const destination = path.join(outputRoot, "raw", name);
  fs.writeFileSync(destination, bytes, { flag: "wx", mode: 0o600 });
  return artifactRecord(repoRoot, destination, "P-32", environmentId, label);
}

export function materializeP32PerformanceSession(
  options,
  {
    installedVerifier = verifyInstalledCandidate,
    manifestPath = INSTALLED_MANIFEST_PATH,
    signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH,
    now = () => new Date(),
    budget = JSON.parse(fs.readFileSync(BUDGET, "utf8")),
  } = {},
) {
  validateP32Invocation(options);
  const repoRoot = directory(options.repoRoot ?? ROOT, "P-32 repository");
  const outputRoot = directory(options.outputRoot, "P-32 output", true);
  const rawRoot = directory(options.rawEvidenceDir, "P-32 raw evidence", true);
  if (!inside(repoRoot, outputRoot))
    throw new Error("P-32 output must be confined to the repository");
  if (
    rawRoot === outputRoot ||
    inside(rawRoot, outputRoot) ||
    inside(outputRoot, rawRoot)
  )
    throw new Error("P-32 raw and output directories must be disjoint");
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-32 requires a supported Linux environment");
  installedVerifier(options);
  const copiedRoot = path.join(outputRoot, "raw");
  fs.mkdirSync(copiedRoot, { mode: 0o700 });
  directory(copiedRoot, "P-32 copied evidence", true);
  const copied = Object.fromEntries(
    P32_RAW_FILES.map((name) => [
      name,
      copy(
        repoRoot,
        rawRoot,
        outputRoot,
        name,
        options.environmentId,
        `P-32 ${name}`,
        true,
      ),
    ]),
  );
  const manifest = copy(
    repoRoot,
    path.dirname(manifestPath),
    outputRoot,
    path.basename(manifestPath),
    options.environmentId,
    "P-32 installed manifest",
    false,
  );
  const signature = copy(
    repoRoot,
    path.dirname(signaturePath),
    outputRoot,
    path.basename(signaturePath),
    options.environmentId,
    "P-32 installed signature",
    false,
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  )
    throw new Error(
      "P-32 installed attestation changed during materialization",
    );
  const receipt = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["p32-native-performance-receipt.json"].path),
    ),
    "P-32 receipt",
  );
  const startedAt = receipt.collectedAt;
  const endedAt = now().toISOString();
  if (Date.parse(endedAt) <= Date.parse(startedAt))
    throw new Error("P-32 materialization time must follow collection");
  const verification = structuredClone(receipt.verification);
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p32-installed-performance-session-v1",
    requirementId: "P-32",
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: {
      runId: String(options.candidateRunId),
      artifactDigest: options.candidateArtifactDigest,
    },
    package: {
      architecture: expected.architecture,
      format: expected.format,
      installed: true,
      manifest,
      signature,
      source: "verified-live-installed-candidate",
      version: options.packageVersion,
    },
    capture: {
      startedAt,
      endedAt,
      fixtureMode: false,
      method: "signed-installed-nightly-performance",
    },
    evidence: copied,
    verification,
  };
  validateP32InstalledSession(
    document,
    { ...options, candidateRunId: String(options.candidateRunId), repoRoot },
    { budget },
  );
  const output = path.join(outputRoot, P32_SESSION_FILENAME);
  if (fs.existsSync(output)) {
    const stat = fs.lstatSync(output);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      stat.uid !== process.getuid?.()
    )
      throw new Error("P-32 session output is not a replaceable owned file");
    fs.rmSync(output);
  }
  atomicWriteJson(output, document);
  return { document, output };
}

function parseArguments(argv) {
  const flags = [
    "--output-root",
    "--raw-evidence-dir",
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
    outputRoot: values.get("--output-root"),
    rawEvidenceDir: values.get("--raw-evidence-dir"),
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
      `${JSON.stringify({ output: materializeP32PerformanceSession(parseArguments(process.argv.slice(2))).output })}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-32 performance materialization failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
