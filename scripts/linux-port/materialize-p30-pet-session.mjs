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
  P30_SESSION_FILENAME,
  validateP30InstalledSession,
} from "./lib/p30-pet-proof.mjs";
import {
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH,
} from "./lib/linux-installed-manifest.mjs";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const RAW_FILES = [
  "pet-marker.json",
  "pet-native-transcript.json",
  "pet-runtime-capabilities.json",
  "pet-initial.png",
  "pet-selected.png",
  "pet-moved.png",
  "pet-relaunch.png",
  "pet-initial-atspi.json",
  "pet-selected-atspi.json",
  "pet-moved-atspi.json",
  "pet-relaunch-atspi.json",
];

function realDirectory(candidate, label, ownerOnly = false) {
  const stat = fs.lstatSync(candidate);
  if (
    !stat.isDirectory() ||
    stat.isSymbolicLink() ||
    stat.uid !== process.getuid?.() ||
    (ownerOnly && (stat.mode & 0o077) !== 0)
  )
    throw new Error(
      `${label} must be a real owned${ownerOnly ? " owner-only" : ""} directory`,
    );
  return fs.realpathSync(candidate);
}

function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return (
    relative !== "" &&
    relative !== ".." &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}

function copy(
  repoRoot,
  rawRoot,
  outputRoot,
  name,
  environmentId,
  label,
  ownerOnly = true,
) {
  const source = path.join(rawRoot, name);
  const stat = fs.lstatSync(source);
  if (
    !stat.isFile() ||
    stat.isSymbolicLink() ||
    stat.uid !== process.getuid?.() ||
    (ownerOnly && (stat.mode & 0o077) !== 0) ||
    fs.realpathSync(path.dirname(source)) !== rawRoot
  )
    throw new Error(`${label} is not a safe live artifact`);
  const destination = path.join(outputRoot, "raw", name);
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(destination, 0o600);
  return artifactRecord(repoRoot, destination, "P-30", environmentId, label);
}

export function materializeP30PetSession(
  options,
  {
    installedVerifier = verifyInstalledCandidate,
    manifestPath = INSTALLED_MANIFEST_PATH,
    signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH,
  } = {},
) {
  const repoRoot = realDirectory(options.repoRoot ?? ROOT, "P-30 repository");
  const outputRoot = realDirectory(options.outputRoot, "P-30 output root");
  const rawRoot = realDirectory(
    options.rawEvidenceDir,
    "P-30 raw evidence",
    true,
  );
  if (!inside(repoRoot, outputRoot))
    throw new Error("P-30 output root must be confined to the repository");
  if (
    rawRoot === outputRoot ||
    inside(rawRoot, outputRoot) ||
    inside(outputRoot, rawRoot)
  )
    throw new Error("P-30 raw and output roots must be disjoint");
  const copiedRoot = path.join(outputRoot, "raw");
  fs.mkdirSync(copiedRoot, { mode: 0o700 });
  realDirectory(copiedRoot, "P-30 copied evidence", true);
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-30 requires a supported Linux environment");
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
        `P-30 ${name}`,
      ),
    ]),
  );
  const copyAttestation = (source, label) => {
    const sourceRoot = realDirectory(path.dirname(source), `${label} source`);
    return copy(
      repoRoot,
      sourceRoot,
      outputRoot,
      path.basename(source),
      options.environmentId,
      label,
      false,
    );
  };
  const manifest = copyAttestation(manifestPath, "P-30 installed manifest");
  const signature = copyAttestation(
    signaturePath,
    "P-30 installed manifest signature",
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  )
    throw new Error(
      "P-30 installed attestation changed during materialization",
    );
  const marker = parseJson(
    fs.readFileSync(path.join(repoRoot, copied["pet-marker.json"].path)),
    "P-30 marker",
  );
  const native = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["pet-native-transcript.json"].path),
    ),
    "P-30 transcript",
  );
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p30-installed-pet-session-v1",
    requirementId: "P-30",
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
      nativeTranscript: copied["pet-native-transcript.json"],
      runtimeManifest: copied["pet-runtime-capabilities.json"],
      initialScreenshot: copied["pet-initial.png"],
      selectedScreenshot: copied["pet-selected.png"],
      movedScreenshot: copied["pet-moved.png"],
      relaunchScreenshot: copied["pet-relaunch.png"],
      initialAccessibility: copied["pet-initial-atspi.json"],
      selectedAccessibility: copied["pet-selected-atspi.json"],
      movedAccessibility: copied["pet-moved-atspi.json"],
      relaunchAccessibility: copied["pet-relaunch-atspi.json"],
    },
  };
  validateP30InstalledSession(document, {
    ...options,
    repoRoot,
    candidateRunId: String(options.candidateRunId),
  });
  const output = path.join(outputRoot, P30_SESSION_FILENAME);
  if (fs.existsSync(output)) {
    const stat = fs.lstatSync(output);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      stat.uid !== process.getuid?.()
    )
      throw new Error("P-30 output session is unsafe");
    fs.rmSync(output);
  }
  atomicWriteJson(output, document);
  return { document, output };
}

function args(argv) {
  const names = [
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
      !names.includes(argv[index]) ||
      values.has(argv[index]) ||
      argv[index + 1] === undefined
    )
      throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const name of names)
    if (!values.has(name)) throw new Error(`${name} is required`);
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
      `${JSON.stringify({ output: materializeP30PetSession(args(process.argv.slice(2))).output })}\n`,
    );
  } catch (error) {
    process.stderr.write(`P-30 pet materialization failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
