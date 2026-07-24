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
  P29_SESSION_FILENAME,
  validateP29InstalledSession,
} from "./lib/p29-text-expansion-proof.mjs";
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
  "text-expansion-marker.json",
  "text-expansion-native-transcript.json",
  "text-expansion-consent.png",
  "text-expansion-created.png",
  "text-expansion-edited.png",
  "text-expansion-expanded.png",
  "text-expansion-secure-denied.png",
  "text-expansion-restored.png",
  "text-expansion-consent-atspi.json",
  "text-expansion-created-atspi.json",
  "text-expansion-edited-atspi.json",
  "text-expansion-expanded-atspi.json",
  "text-expansion-secure-denied-atspi.json",
  "text-expansion-restored-atspi.json",
]);
const EVIDENCE_FIELDS = Object.freeze({
  "text-expansion-native-transcript.json": "nativeTranscript",
  "text-expansion-consent.png": "consentScreenshot",
  "text-expansion-created.png": "createdScreenshot",
  "text-expansion-edited.png": "editedScreenshot",
  "text-expansion-expanded.png": "expandedScreenshot",
  "text-expansion-secure-denied.png": "secureDeniedScreenshot",
  "text-expansion-restored.png": "restoredScreenshot",
  "text-expansion-consent-atspi.json": "consentAccessibility",
  "text-expansion-created-atspi.json": "createdAccessibility",
  "text-expansion-edited-atspi.json": "editedAccessibility",
  "text-expansion-expanded-atspi.json": "expandedAccessibility",
  "text-expansion-secure-denied-atspi.json": "secureDeniedAccessibility",
  "text-expansion-restored-atspi.json": "restoredAccessibility",
});
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
  const supplied = path.resolve(value);
  const stat = fs.lstatSync(supplied);
  if (
    !stat.isDirectory() ||
    stat.isSymbolicLink() ||
    fs.realpathSync(supplied) !== supplied ||
    stat.uid !== process.getuid?.() ||
    (ownerOnly && (stat.mode & 0o077) !== 0)
  )
    throw new Error(
      `${label} must be a canonical ${ownerOnly ? "owner-only " : ""}directory`,
    );
  return supplied;
}
function copy(
  repoRoot,
  sourceRoot,
  outputRoot,
  name,
  environmentId,
  label,
  ownerOnly = false,
) {
  if (path.basename(name) !== name)
    throw new Error(`${label} must be a basename`);
  const source = path.join(sourceRoot, name);
  if (!inside(sourceRoot, source) || fs.realpathSync(source) !== source)
    throw new Error(`${label} escapes its source directory`);
  const descriptor = fs.openSync(
    source,
    fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0),
  );
  let bytes;
  try {
    const stat = fs.fstatSync(descriptor);
    if (
      !stat.isFile() ||
      (ownerOnly
        ? stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0
        : (stat.mode & 0o022) !== 0)
    )
      throw new Error(`${label} permissions are unsafe`);
    bytes = fs.readFileSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  const destination = path.join(outputRoot, "raw", name);
  fs.writeFileSync(destination, bytes, { flag: "wx", mode: 0o600 });
  return artifactRecord(repoRoot, destination, "P-29", environmentId, label);
}

export function materializeP29TextExpansionSession(
  options,
  {
    installedVerifier = verifyInstalledCandidate,
    manifestPath = INSTALLED_MANIFEST_PATH,
    signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH,
  } = {},
) {
  const repoRoot = directory(options.repoRoot ?? ROOT, "P-29 repository");
  const outputRoot = directory(options.outputRoot, "P-29 output root");
  const rawRoot = directory(options.rawEvidenceDir, "P-29 raw evidence", true);
  if (!inside(repoRoot, outputRoot))
    throw new Error("P-29 output root must remain inside the repository");
  if (
    rawRoot === outputRoot ||
    inside(rawRoot, outputRoot) ||
    inside(outputRoot, rawRoot)
  )
    throw new Error("P-29 raw and materialized roots must be disjoint");
  const copiedRoot = path.join(outputRoot, "raw");
  fs.mkdirSync(copiedRoot, { mode: 0o700 });
  directory(copiedRoot, "P-29 copied evidence", true);
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-29 requires a supported environment");
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
        `P-29 ${name}`,
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
    "P-29 installed manifest",
  );
  const signature = copy(
    repoRoot,
    path.dirname(signaturePath),
    outputRoot,
    path.basename(signaturePath),
    options.environmentId,
    "P-29 installed manifest signature",
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  )
    throw new Error(
      "P-29 installed attestation changed during materialization",
    );
  const marker = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["text-expansion-marker.json"].path),
    ),
    "P-29 marker",
  );
  const native = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["text-expansion-native-transcript.json"].path),
    ),
    "P-29 native transcript",
  );
  const evidence = {};
  for (const [name, field] of Object.entries(EVIDENCE_FIELDS))
    evidence[field] = copied[name];
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p29-installed-text-expansion-session-v1",
    requirementId: "P-29",
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
    evidence,
  };
  validateP29InstalledSession(
    document,
    { ...options, candidateRunId: String(options.candidateRunId), repoRoot },
    { repoRoot },
  );
  const output = path.join(outputRoot, P29_SESSION_FILENAME);
  if (fs.existsSync(output)) {
    const stat = fs.lstatSync(output);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      stat.uid !== process.getuid?.()
    )
      throw new Error("P-29 output session is unsafe");
    fs.rmSync(output);
  }
  atomicWriteJson(output, document);
  return { document, output };
}
