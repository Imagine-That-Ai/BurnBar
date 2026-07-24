#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  artifactRecord,
  INSTALLED_UI_ENVIRONMENTS,
  parseJson,
} from "./lib/installed-ui-proof.mjs";
import {
  P16_RAW_FILES,
  P16_SESSION_FILENAME,
  P16_STATES,
  validateP16InstalledSession,
} from "./lib/p16-cloud-devices-proof.mjs";
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
    throw new Error(`${label} is not a safe live artifact`);
  const destination = path.join(outputRoot, "raw", name);
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(destination, 0o600);
  return artifactRecord(repoRoot, destination, "P-16", environmentId, label);
}

export function materializeP16CloudDevicesSession(options, dependencies = {}) {
  const repoRoot = directory(options.repoRoot ?? ROOT, "P-16 repository");
  const outputRoot = directory(options.outputRoot, "P-16 output root");
  const rawRoot = directory(options.rawEvidenceDir, "P-16 raw evidence", true);
  if (!inside(repoRoot, outputRoot))
    throw new Error("P-16 output root must be confined to the repository");
  if (
    rawRoot === outputRoot ||
    inside(rawRoot, outputRoot) ||
    inside(outputRoot, rawRoot)
  )
    throw new Error("P-16 raw and output roots must be disjoint");
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-16 requires a supported Linux environment");
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  fs.mkdirSync(path.join(outputRoot, "raw"), { mode: 0o700 });
  const copied = Object.fromEntries(
    P16_RAW_FILES.map((name) => [
      name,
      copy(
        repoRoot,
        rawRoot,
        outputRoot,
        name,
        options.environmentId,
        `P-16 ${name}`,
      ),
    ]),
  );
  const manifestPath = dependencies.manifestPath ?? INSTALLED_MANIFEST_PATH;
  const signaturePath =
    dependencies.signaturePath ?? INSTALLED_MANIFEST_SIGNATURE_PATH;
  const manifest = copy(
    repoRoot,
    directory(path.dirname(manifestPath), "P-16 manifest directory"),
    outputRoot,
    path.basename(manifestPath),
    options.environmentId,
    "P-16 installed manifest",
    false,
  );
  const signature = copy(
    repoRoot,
    directory(path.dirname(signaturePath), "P-16 signature directory"),
    outputRoot,
    path.basename(signaturePath),
    options.environmentId,
    "P-16 installed manifest signature",
    false,
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  )
    throw new Error(
      "P-16 installed attestation changed during materialization",
    );
  const marker = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["cloud-devices-marker.json"].path),
    ),
    "P-16 marker",
  );
  const native = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["cloud-devices-native-transcript.json"].path),
    ),
    "P-16 transcript",
  );
  const evidence = {
    coordinationRequest: copied["cloud-devices-coordination-request.json"],
    revocationReady: copied["cloud-devices-revocation-ready.json"],
    nativeTranscript: copied["cloud-devices-native-transcript.json"],
    mobileReceipt: copied["cloud-devices-mobile-receipt.json"],
  };
  for (const state of P16_STATES) {
    evidence[`${state}Screenshot`] = copied[`cloud-devices-${state}.png`];
    evidence[`${state}Accessibility`] =
      copied[`cloud-devices-${state}-atspi.json`];
  }
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p16-installed-cloud-devices-session-v1",
    requirementId: "P-16",
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
      desktop: options.desktop,
      displayServer: options.displayServer,
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
  const output = path.join(outputRoot, P16_SESSION_FILENAME);
  fs.writeFileSync(output, `${JSON.stringify(document, null, 2)}\n`, {
    flag: "wx",
    mode: 0o600,
  });
  validateP16InstalledSession(document, {
    ...options,
    repoRoot,
    candidateRunId: String(options.candidateRunId),
  });
  return { document, output };
}

function parseArguments(argv) {
  const flags = [
    "--output-root",
    "--raw-evidence-dir",
    "--environment",
    "--desktop",
    "--display-server",
    "--compositor",
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
    desktop: values.get("--desktop"),
    displayServer: values.get("--display-server"),
    compositor: values.get("--compositor"),
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
    const result = materializeP16CloudDevicesSession(
      parseArguments(process.argv.slice(2)),
    );
    process.stdout.write(`${JSON.stringify({ output: result.output })}\n`);
  } catch (error) {
    process.stderr.write(`P-16 materialization failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
