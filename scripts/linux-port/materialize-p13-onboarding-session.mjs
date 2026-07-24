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
  P13_SESSION_FILENAME,
  validateP13InstalledSession,
} from "./lib/p13-onboarding-proof.mjs";
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
  "onboarding-marker.json",
  "onboarding-daemon-transcript.json",
  "onboarding-ui-transcript.json",
  "onboarding-provider.png",
  "onboarding-cloud.png",
  "onboarding-privacy.png",
  "onboarding-completed.png",
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
  return artifactRecord(repoRoot, destination, "P-13", environmentId, label);
}

export function materializeP13OnboardingSession(
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
  if (!expected) throw new Error("P-13 requires a supported Linux environment");
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
        `P-13 ${name}`,
      ),
    ]),
  );
  const manifest = copy(
    repoRoot,
    path.dirname(manifestPath),
    outputRoot,
    path.basename(manifestPath),
    options.environmentId,
    "P-13 installed manifest",
  );
  const signature = copy(
    repoRoot,
    path.dirname(signaturePath),
    outputRoot,
    path.basename(signaturePath),
    options.environmentId,
    "P-13 installed manifest signature",
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  ) {
    throw new Error(
      "P-13 installed attestation changed during materialization",
    );
  }
  const marker = parseJson(
    fs.readFileSync(path.join(repoRoot, copied["onboarding-marker.json"].path)),
    "P-13 marker",
  );
  const daemon = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["onboarding-daemon-transcript.json"].path),
    ),
    "P-13 daemon transcript",
  );
  const ui = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["onboarding-ui-transcript.json"].path),
    ),
    "P-13 UI transcript",
  );
  const times = [
    ...daemon.events.map((event) => Date.parse(event.at)),
    ...ui.events.map((event) => Date.parse(event.at)),
  ];
  if (times.length === 0 || times.some((time) => !Number.isFinite(time)))
    throw new Error("P-13 evidence timestamps are invalid");
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p13-installed-onboarding-session-v1",
    requirementId: "P-13",
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
      daemonTranscript: copied["onboarding-daemon-transcript.json"],
      uiTranscript: copied["onboarding-ui-transcript.json"],
      providerScreenshot: copied["onboarding-provider.png"],
      cloudScreenshot: copied["onboarding-cloud.png"],
      privacyScreenshot: copied["onboarding-privacy.png"],
      completedScreenshot: copied["onboarding-completed.png"],
    },
  };
  validateP13InstalledSession(
    document,
    { ...options, candidateRunId: String(options.candidateRunId) },
    { repoRoot },
  );
  const output = path.join(outputRoot, P13_SESSION_FILENAME);
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
      `${JSON.stringify({ output: materializeP13OnboardingSession(args(process.argv.slice(2))).output })}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-13 onboarding session materialization failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
