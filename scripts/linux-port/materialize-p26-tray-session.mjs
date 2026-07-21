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
  P26_SESSION_FILENAME,
  validateP26InstalledSession,
} from "./lib/p26-tray-proof.mjs";
import {
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH,
} from "./lib/linux-installed-manifest.mjs";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const RAW_FILES = Object.freeze([
  "tray-marker.json",
  "tray-native-transcript.json",
  "tray-background.png",
  "tray-dashboard.png",
  "tray-chat.png",
  "tray-usage.png",
  "tray-updates.png",
  "tray-settings.png",
  "tray-dashboard-atspi.json",
  "tray-chat-atspi.json",
  "tray-usage-atspi.json",
  "tray-updates-atspi.json",
  "tray-settings-atspi.json",
]);

function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return (
    relative !== "" &&
    relative !== ".." &&
    !relative.startsWith(`..${path.sep}`)
  );
}
function realDirectory(directory, label, { ownerOnly = false } = {}) {
  const supplied = path.resolve(directory);
  const stat = fs.lstatSync(supplied);
  const real = fs.realpathSync(supplied);
  if (
    !stat.isDirectory() ||
    stat.isSymbolicLink() ||
    real !== supplied ||
    stat.uid !== process.getuid?.() ||
    (ownerOnly && (stat.mode & 0o077) !== 0)
  )
    throw new Error(
      `${label} must be a canonical ${ownerOnly ? "owner-only " : ""}directory`,
    );
  return real;
}
function copy(
  repoRoot,
  sourceRoot,
  outputRoot,
  name,
  environmentId,
  label,
  { ownerOnly = false } = {},
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
      throw new Error(
        `${label} must be a ${ownerOnly ? "owner-only " : "non-writable "}regular non-symlink file`,
      );
    bytes = fs.readFileSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  const destination = path.join(outputRoot, "raw", name);
  fs.writeFileSync(destination, bytes, { flag: "wx", mode: 0o600 });
  return artifactRecord(repoRoot, destination, "P-26", environmentId, label);
}

export function materializeP26TraySession(
  options,
  {
    installedVerifier = verifyInstalledCandidate,
    manifestPath = INSTALLED_MANIFEST_PATH,
    signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH,
  } = {},
) {
  const repoRoot = realDirectory(options.repoRoot ?? ROOT, "P-26 repository");
  const outputRoot = realDirectory(options.outputRoot, "P-26 output root");
  const rawRoot = realDirectory(options.rawEvidenceDir, "P-26 raw evidence", {
    ownerOnly: true,
  });
  if (!inside(repoRoot, outputRoot))
    throw new Error("P-26 output root must be confined to the repository");
  if (
    rawRoot === outputRoot ||
    inside(rawRoot, outputRoot) ||
    inside(outputRoot, rawRoot)
  )
    throw new Error("P-26 raw evidence and output roots must be disjoint");
  const copiedRoot = path.join(outputRoot, "raw");
  try {
    fs.lstatSync(copiedRoot);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    fs.mkdirSync(copiedRoot, { mode: 0o700 });
  }
  realDirectory(copiedRoot, "P-26 copied evidence", { ownerOnly: true });
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-26 requires a supported Linux environment");
  installedVerifier(options);
  const copied = Object.fromEntries(
    RAW_FILES.map((name) => [
      name,
      copy(
        repoRoot,
        rawRoot,
        outputRoot,
        name,
        options.environmentId,
        `P-26 ${name}`,
        { ownerOnly: true },
      ),
    ]),
  );
  const manifest = copy(
    repoRoot,
    path.dirname(manifestPath),
    outputRoot,
    path.basename(manifestPath),
    options.environmentId,
    "P-26 installed manifest",
  );
  const signature = copy(
    repoRoot,
    path.dirname(signaturePath),
    outputRoot,
    path.basename(signaturePath),
    options.environmentId,
    "P-26 installed manifest signature",
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  )
    throw new Error(
      "P-26 installed attestation changed during materialization",
    );
  const marker = parseJson(
    fs.readFileSync(path.join(repoRoot, copied["tray-marker.json"].path)),
    "P-26 marker",
  );
  const native = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["tray-native-transcript.json"].path),
    ),
    "P-26 native transcript",
  );
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p26-installed-tray-session-v1",
    requirementId: "P-26",
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
    desktop: {
      compositor: options.compositor,
      desktop: expected.desktop,
      displayServer: expected.session,
      liveSession: true,
    },
    capture: {
      startedAt: native.startedAt,
      endedAt: native.endedAt,
      fixtureMode: false,
      method: "installed-live-product-session",
    },
    marker,
    evidence: {
      nativeTranscript: copied["tray-native-transcript.json"],
      backgroundScreenshot: copied["tray-background.png"],
      dashboardScreenshot: copied["tray-dashboard.png"],
      chatScreenshot: copied["tray-chat.png"],
      usageScreenshot: copied["tray-usage.png"],
      updatesScreenshot: copied["tray-updates.png"],
      settingsScreenshot: copied["tray-settings.png"],
      dashboardAccessibility: copied["tray-dashboard-atspi.json"],
      chatAccessibility: copied["tray-chat-atspi.json"],
      usageAccessibility: copied["tray-usage-atspi.json"],
      updatesAccessibility: copied["tray-updates-atspi.json"],
      settingsAccessibility: copied["tray-settings-atspi.json"],
    },
  };
  validateP26InstalledSession(
    document,
    { ...options, candidateRunId: String(options.candidateRunId), repoRoot },
    { repoRoot },
  );
  const output = path.join(outputRoot, P26_SESSION_FILENAME);
  if (fs.existsSync(output)) {
    const stat = fs.lstatSync(output);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      stat.uid !== process.getuid?.()
    )
      throw new Error("P-26 output session is not a replaceable owned file");
    fs.rmSync(output);
  }
  atomicWriteJson(output, document);
  return { document, output };
}

function args(argv) {
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
    "--compositor",
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
    compositor: values.get("--compositor"),
  };
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    process.stdout.write(
      `${JSON.stringify({ output: materializeP26TraySession(args(process.argv.slice(2))).output })}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-26 tray session materialization failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
