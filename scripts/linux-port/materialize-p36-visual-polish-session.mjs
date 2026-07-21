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
  P36_RAW_FILES,
  P36_SESSION_FILENAME,
  validateP36InstalledSession,
} from "./lib/p36-visual-polish-proof.mjs";
import {
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH,
} from "./lib/linux-installed-manifest.mjs";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";
const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
function directory(candidate, label, ownerOnly = false) {
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
  sourceRoot,
  outputRoot,
  name,
  environmentId,
  label,
  ownerOnly = true,
) {
  const source = path.join(sourceRoot, name);
  const stat = fs.lstatSync(source);
  if (
    !stat.isFile() ||
    stat.isSymbolicLink() ||
    stat.uid !== process.getuid?.() ||
    (ownerOnly && (stat.mode & 0o077) !== 0) ||
    fs.realpathSync(path.dirname(source)) !== sourceRoot
  )
    throw new Error(`${label} is unsafe`);
  const destination = path.join(outputRoot, "raw", name);
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(destination, 0o600);
  return artifactRecord(repoRoot, destination, "P-36", environmentId, label);
}
export function materializeP36VisualPolishSession(options, dependencies = {}) {
  const repoRoot = directory(options.repoRoot ?? ROOT, "P-36 repository");
  const outputRoot = directory(options.outputRoot, "P-36 output root");
  const rawRoot = directory(options.rawEvidenceDir, "P-36 raw evidence", true);
  if (
    !inside(repoRoot, outputRoot) ||
    rawRoot === outputRoot ||
    inside(rawRoot, outputRoot) ||
    inside(outputRoot, rawRoot)
  )
    throw new Error("P-36 roots must be confined and disjoint");
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-36 environment unsupported");
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  fs.mkdirSync(path.join(outputRoot, "raw"), { mode: 0o700 });
  const copied = Object.fromEntries(
    P36_RAW_FILES.map((name) => [
      name,
      copy(
        repoRoot,
        rawRoot,
        outputRoot,
        name,
        options.environmentId,
        `P-36 ${name}`,
      ),
    ]),
  );
  const manifestPath = dependencies.manifestPath ?? INSTALLED_MANIFEST_PATH;
  const signaturePath =
    dependencies.signaturePath ?? INSTALLED_MANIFEST_SIGNATURE_PATH;
  const manifest = copy(
    repoRoot,
    directory(path.dirname(manifestPath), "P-36 manifest directory"),
    outputRoot,
    path.basename(manifestPath),
    options.environmentId,
    "P-36 installed manifest",
    false,
  );
  const signature = copy(
    repoRoot,
    directory(path.dirname(signaturePath), "P-36 signature directory"),
    outputRoot,
    path.basename(signaturePath),
    options.environmentId,
    "P-36 installed manifest signature",
    false,
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  )
    throw new Error("P-36 attestation changed");
  const marker = parseJson(
    fs.readFileSync(path.join(repoRoot, copied["visual-marker.json"].path)),
    "P-36 marker",
  );
  const native = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["visual-native-transcript.json"].path),
    ),
    "P-36 transcript",
  );
  const evidence = {
    nativeTranscript: copied["visual-native-transcript.json"],
    compactLightScreenshot: copied["visual-compact-light.png"],
    standardDarkScreenshot: copied["visual-standard-dark.png"],
    wideDarkScreenshot: copied["visual-wide-dark.png"],
    reducedMotionScreenshot: copied["visual-reduced-motion.png"],
    overflowMenuScreenshot: copied["visual-overflow-menu.png"],
    compactAccessibility: copied["visual-compact-atspi.json"],
    standardAccessibility: copied["visual-standard-atspi.json"],
    wideAccessibility: copied["visual-wide-atspi.json"],
    reducedAccessibility: copied["visual-reduced-atspi.json"],
    overflowAccessibility: copied["visual-overflow-atspi.json"],
  };
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p36-installed-visual-polish-session-v1",
    requirementId: "P-36",
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
  validateP36InstalledSession(document, {
    ...options,
    repoRoot,
    candidateRunId: String(options.candidateRunId),
  });
  const output = path.join(outputRoot, P36_SESSION_FILENAME);
  if (fs.existsSync(output))
    throw new Error(
      "P-36 materialization refuses to replace an existing session",
    );
  atomicWriteJson(output, document);
  return { document, output };
}
function parseArgs(argv) {
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
      `${JSON.stringify(materializeP36VisualPolishSession(parseArgs(process.argv.slice(2))))}\n`,
    );
  } catch (error) {
    process.stderr.write(`P-36 materialization failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
