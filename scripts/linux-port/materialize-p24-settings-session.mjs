#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  artifactRecord,
  atomicWriteJson,
  INSTALLED_UI_ENVIRONMENTS,
} from "./lib/installed-ui-proof.mjs";
import {
  P24_SESSION_FILENAME,
  validateP24InstalledSession,
} from "./lib/p24-settings-proof.mjs";
import {
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH,
} from "./lib/linux-installed-manifest.mjs";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
function copy(repoRoot, sourceRoot, outputRoot, name, environmentId, label) {
  if (path.basename(name) !== name)
    throw new Error(`${label} must be a basename`);
  const source = path.join(sourceRoot, name);
  const stat = fs.lstatSync(source);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0)
    throw new Error(`${label} must be owner-only and regular`);
  const destination = path.join(outputRoot, "raw", name);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(destination, 0o600);
  return artifactRecord(repoRoot, destination, "P-24", environmentId, label);
}
export function materializeP24SettingsSession(
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
  if (!expected) throw new Error("P-24 requires a supported Linux environment");
  installedVerifier(options);
  const transcript = JSON.parse(
    fs.readFileSync(
      path.join(rawRoot, "settings-native-transcript.json"),
      "utf8",
    ),
  );
  const names = [
    "settings-native-transcript.json",
    ...transcript.tabs.map((tab) => tab.screenshot),
    transcript.recovery.degraded.screenshot,
    transcript.recovery.recovered.screenshot,
  ];
  if (new Set(names).size !== 19)
    throw new Error("P-24 requires 19 unique raw evidence files");
  const copied = new Map(
    names.map((name) => [
      name,
      copy(
        repoRoot,
        rawRoot,
        outputRoot,
        name,
        options.environmentId,
        `P-24 ${name}`,
      ),
    ]),
  );
  const manifest = copy(
    repoRoot,
    path.dirname(manifestPath),
    outputRoot,
    path.basename(manifestPath),
    options.environmentId,
    "P-24 installed manifest",
  );
  const signature = copy(
    repoRoot,
    path.dirname(signaturePath),
    outputRoot,
    path.basename(signaturePath),
    options.environmentId,
    "P-24 installed manifest signature",
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  )
    throw new Error(
      "P-24 installed attestation changed during materialization",
    );
  const times = [
    ...transcript.tabs.map((tab) => Date.parse(tab.at)),
    Date.parse(transcript.recovery.degraded.at),
    Date.parse(transcript.recovery.recovered.at),
  ];
  if (times.some((value) => !Number.isFinite(value)))
    throw new Error("P-24 evidence timestamps are invalid");
  const document = {
    schemaVersion: 2,
    id: "openburnbar-linux-p24-installed-settings-session-v2",
    requirementId: "P-24",
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
    marker: transcript.marker,
    settings: {
      deepLink: "openburnbar://settings",
      tabs: transcript.tabs.map((tab) => ({
        ...tab,
        screenshot: copied.get(tab.screenshot),
      })),
      tabOwnership: transcript.tabOwnership,
      writeReceipts: transcript.writeReceipts,
    },
    recovery: {
      restartCount: transcript.recovery.restartCount,
      degraded: {
        ...transcript.recovery.degraded,
        screenshot: copied.get(transcript.recovery.degraded.screenshot),
      },
      recovered: {
        ...transcript.recovery.recovered,
        screenshot: copied.get(transcript.recovery.recovered.screenshot),
      },
    },
    evidence: {
      nativeTranscript: copied.get("settings-native-transcript.json"),
    },
  };
  validateP24InstalledSession(
    document,
    { ...options, candidateRunId: String(options.candidateRunId) },
    { repoRoot },
  );
  const output = path.join(outputRoot, P24_SESSION_FILENAME);
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
      `${JSON.stringify({ output: materializeP24SettingsSession(args(process.argv.slice(2))).output })}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-24 Settings session materialization failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
