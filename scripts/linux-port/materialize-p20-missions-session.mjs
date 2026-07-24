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
  P20_SESSION_FILENAME,
  validateP20InstalledSession,
} from "./lib/p20-missions-proof.mjs";
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
  "missions-marker.json",
  "missions-daemon-transcript.json",
  "missions-ui-transcript.json",
  "missions-pending.png",
  "missions-approved.png",
  "missions-question.png",
  "missions-detail.png",
  "missions-cancelled.png",
]);

function copy(repoRoot, sourceRoot, outputRoot, name, environmentId, label) {
  if (path.basename(name) !== name)
    throw new Error(`${label} must be a basename`);
  const source = path.join(sourceRoot, name);
  const stat = fs.lstatSync(source);
  if (!stat.isFile() || stat.isSymbolicLink())
    throw new Error(`${label} must be a regular non-symlink file`);
  const destination = path.join(outputRoot, "raw", name);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  return artifactRecord(repoRoot, destination, "P-20", environmentId, label);
}

export function materializeP20MissionsSession(
  options,
  {
    installedVerifier = verifyInstalledCandidate,
    manifestPath = INSTALLED_MANIFEST_PATH,
    signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH,
  } = {},
) {
  const repoRoot = fs.realpathSync(options.repoRoot ?? ROOT);
  const outputRoot = fs.realpathSync(options.outputRoot);
  const rawRoot = fs.realpathSync(options.rawEvidenceDir);
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-20 requires a supported Linux environment");
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
        `P-20 ${name}`,
      ),
    ]),
  );
  const manifest = copy(
    repoRoot,
    path.dirname(manifestPath),
    outputRoot,
    path.basename(manifestPath),
    options.environmentId,
    "P-20 installed manifest",
  );
  const signature = copy(
    repoRoot,
    path.dirname(signaturePath),
    outputRoot,
    path.basename(signaturePath),
    options.environmentId,
    "P-20 installed manifest signature",
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  ) {
    throw new Error(
      "P-20 installed attestation changed during materialization",
    );
  }
  const marker = parseJson(
    fs.readFileSync(path.join(repoRoot, copied["missions-marker.json"].path)),
    "P-20 marker",
  );
  const daemon = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["missions-daemon-transcript.json"].path),
    ),
    "P-20 daemon transcript",
  );
  const ui = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["missions-ui-transcript.json"].path),
    ),
    "P-20 UI transcript",
  );
  const times = [
    ...daemon.events.map((event) => Date.parse(event.at)),
    ...ui.events.map((event) => Date.parse(event.at)),
  ];
  if (times.length === 0 || times.some((time) => !Number.isFinite(time)))
    throw new Error("P-20 evidence timestamps are invalid");
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p20-installed-missions-session-v1",
    requirementId: "P-20",
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
      startedAt: new Date(Math.min(...times)).toISOString(),
      endedAt: new Date(Math.max(...times)).toISOString(),
      fixtureMode: false,
      method: "installed-live-product-session",
    },
    marker,
    evidence: {
      daemonTranscript: copied["missions-daemon-transcript.json"],
      uiTranscript: copied["missions-ui-transcript.json"],
      pendingScreenshot: copied["missions-pending.png"],
      approvedScreenshot: copied["missions-approved.png"],
      questionScreenshot: copied["missions-question.png"],
      detailScreenshot: copied["missions-detail.png"],
      cancelledScreenshot: copied["missions-cancelled.png"],
    },
  };
  validateP20InstalledSession(
    document,
    { ...options, candidateRunId: String(options.candidateRunId) },
    { repoRoot },
  );
  const output = path.join(outputRoot, P20_SESSION_FILENAME);
  fs.rmSync(output, { force: true });
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
      `${JSON.stringify({ output: materializeP20MissionsSession(args(process.argv.slice(2))).output })}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-20 missions session materialization failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
