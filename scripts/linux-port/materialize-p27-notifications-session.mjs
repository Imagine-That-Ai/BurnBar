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
  P27_SESSION_FILENAME,
  validateP27InstalledSession,
} from "./lib/p27-notifications-proof.mjs";
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
  "notification-marker.json",
  "notification-native-transcript.json",
  "notification-runtime-capabilities.json",
  "notification-open.png",
  "notification-reply.png",
  "notification-cold.png",
  "notification-warm.png",
  "notification-open-atspi.json",
  "notification-reply-atspi.json",
  "notification-cold-atspi.json",
  "notification-warm-atspi.json",
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
  return artifactRecord(repoRoot, destination, "P-27", environmentId, label);
}

export function materializeP27NotificationsSession(
  options,
  {
    installedVerifier = verifyInstalledCandidate,
    manifestPath = INSTALLED_MANIFEST_PATH,
    signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH,
  } = {},
) {
  const repoRoot = realDirectory(options.repoRoot ?? ROOT, "P-27 repository");
  const outputRoot = realDirectory(options.outputRoot, "P-27 output root");
  const rawRoot = realDirectory(
    options.rawEvidenceDir,
    "P-27 raw evidence",
    true,
  );
  if (!inside(repoRoot, outputRoot))
    throw new Error("P-27 output root must be confined to the repository");
  if (
    rawRoot === outputRoot ||
    inside(rawRoot, outputRoot) ||
    inside(outputRoot, rawRoot)
  )
    throw new Error("P-27 raw and output roots must be disjoint");
  const copiedRoot = path.join(outputRoot, "raw");
  fs.mkdirSync(copiedRoot, { mode: 0o700 });
  realDirectory(copiedRoot, "P-27 copied evidence", true);
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-27 requires a supported Linux environment");
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
        `P-27 ${name}`,
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
  const manifest = copyAttestation(manifestPath, "P-27 installed manifest");
  const signature = copyAttestation(
    signaturePath,
    "P-27 installed manifest signature",
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  )
    throw new Error(
      "P-27 installed attestation changed during materialization",
    );
  const marker = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["notification-marker.json"].path),
    ),
    "P-27 marker",
  );
  const native = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["notification-native-transcript.json"].path),
    ),
    "P-27 transcript",
  );
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p27-installed-notifications-session-v1",
    requirementId: "P-27",
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
      nativeTranscript: copied["notification-native-transcript.json"],
      runtimeManifest: copied["notification-runtime-capabilities.json"],
      openScreenshot: copied["notification-open.png"],
      replyScreenshot: copied["notification-reply.png"],
      coldScreenshot: copied["notification-cold.png"],
      warmScreenshot: copied["notification-warm.png"],
      openAccessibility: copied["notification-open-atspi.json"],
      replyAccessibility: copied["notification-reply-atspi.json"],
      coldAccessibility: copied["notification-cold-atspi.json"],
      warmAccessibility: copied["notification-warm-atspi.json"],
    },
  };
  validateP27InstalledSession(document, {
    ...options,
    repoRoot,
    candidateRunId: String(options.candidateRunId),
  });
  const output = path.join(outputRoot, P27_SESSION_FILENAME);
  if (fs.existsSync(output)) {
    const stat = fs.lstatSync(output);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      stat.uid !== process.getuid?.()
    )
      throw new Error("P-27 output session is unsafe");
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
      `${JSON.stringify({ output: materializeP27NotificationsSession(args(process.argv.slice(2))).output })}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-27 notification materialization failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
