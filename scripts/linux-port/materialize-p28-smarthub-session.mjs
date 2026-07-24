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
  P28_RAW_FILES,
  P28_SESSION_FILENAME,
  P28_STATES,
  validateP28InstalledSession,
} from "./lib/p28-smarthub-proof.mjs";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const COMPOSITOR = Object.freeze({
  GNOME: "Mutter",
  "KDE Plasma": "KWin",
  "Sway/wlroots": "Sway",
});

function realDirectory(candidate, label, ownerOnly = false) {
  const absolute = path.resolve(candidate);
  const stat = fs.lstatSync(absolute);
  if (
    !stat.isDirectory() ||
    stat.isSymbolicLink() ||
    fs.realpathSync(absolute) !== absolute ||
    stat.uid !== process.getuid?.() ||
    (ownerOnly && (stat.mode & 0o077) !== 0)
  ) {
    throw new Error(
      `${label} must be a canonical owned${ownerOnly ? " owner-only" : ""} directory`,
    );
  }
  return absolute;
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
  if (path.basename(name) !== name)
    throw new Error(`${label} must be a basename`);
  const source = path.join(sourceRoot, name);
  const descriptor = fs.openSync(
    source,
    fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0),
  );
  let bytes;
  try {
    const stat = fs.fstatSync(descriptor);
    if (
      !stat.isFile() ||
      stat.uid !== process.getuid?.() ||
      (ownerOnly && (stat.mode & 0o077) !== 0) ||
      (!ownerOnly && (stat.mode & 0o022) !== 0) ||
      fs.realpathSync(path.dirname(source)) !== sourceRoot
    ) {
      throw new Error(`${label} is not a safe immutable artifact`);
    }
    bytes = fs.readFileSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  const destination = path.join(outputRoot, "raw", name);
  fs.writeFileSync(destination, bytes, { flag: "wx", mode: 0o600 });
  return artifactRecord(repoRoot, destination, "P-28", environmentId, label);
}

export function materializeP28SmartHubSession(
  options,
  {
    installedVerifier = verifyInstalledCandidate,
    manifestPath = INSTALLED_MANIFEST_PATH,
    signaturePath = INSTALLED_MANIFEST_SIGNATURE_PATH,
  } = {},
) {
  const repoRoot = realDirectory(options.repoRoot ?? ROOT, "P-28 repository");
  const outputRoot = realDirectory(options.outputRoot, "P-28 output root");
  const rawRoot = realDirectory(
    options.rawEvidenceDir,
    "P-28 raw evidence",
    true,
  );
  if (!inside(repoRoot, outputRoot))
    throw new Error("P-28 output root must be confined to the repository");
  if (
    rawRoot === outputRoot ||
    inside(rawRoot, outputRoot) ||
    inside(outputRoot, rawRoot)
  )
    throw new Error("P-28 raw and output roots must be disjoint");
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  if (!expected) throw new Error("P-28 requires a supported Linux environment");
  if (options.compositor !== COMPOSITOR[expected.desktop])
    throw new Error("P-28 compositor does not match the selected live desktop");
  const rawNames = fs.readdirSync(rawRoot).sort();
  if (JSON.stringify(rawNames) !== JSON.stringify([...P28_RAW_FILES].sort()))
    throw new Error(
      "P-28 raw evidence must contain exactly the native runner artifacts",
    );
  installedVerifier(options);
  const copiedRoot = path.join(outputRoot, "raw");
  if (
    fs.existsSync(copiedRoot) ||
    fs.lstatSync(copiedRoot, { throwIfNoEntry: false })
  ) {
    throw new Error("P-28 output evidence already exists; refusing replay");
  }
  fs.mkdirSync(copiedRoot, { mode: 0o700 });
  realDirectory(copiedRoot, "P-28 copied evidence", true);
  const copied = Object.fromEntries(
    P28_RAW_FILES.map((name) => [
      name,
      copy(
        repoRoot,
        rawRoot,
        outputRoot,
        name,
        options.environmentId,
        `P-28 ${name}`,
      ),
    ]),
  );
  const copyAttestation = (source, label) =>
    copy(
      repoRoot,
      realDirectory(path.dirname(source), `${label} source`),
      outputRoot,
      path.basename(source),
      options.environmentId,
      label,
      false,
    );
  const manifest = copyAttestation(manifestPath, "P-28 installed manifest");
  const signature = copyAttestation(
    signaturePath,
    "P-28 installed manifest signature",
  );
  if (
    manifest.sha256 !== options.manifestSha256 ||
    signature.sha256 !== options.manifestSignatureSha256
  ) {
    throw new Error(
      "P-28 installed attestation changed during materialization",
    );
  }
  const marker = parseJson(
    fs.readFileSync(path.join(repoRoot, copied["smarthub-marker.json"].path)),
    "P-28 marker",
  );
  const native = parseJson(
    fs.readFileSync(
      path.join(repoRoot, copied["smarthub-native-transcript.json"].path),
    ),
    "P-28 native transcript",
  );
  const evidence = {
    marker: copied["smarthub-marker.json"],
    nativeTranscript: copied["smarthub-native-transcript.json"],
    peerManifest: copied["smarthub-peer-manifest.json"],
  };
  for (const state of P28_STATES) {
    evidence[`${state}Screenshot`] = copied[`smarthub-${state}.png`];
    evidence[`${state}Accessibility`] = copied[`smarthub-${state}-atspi.json`];
  }
  const document = {
    schemaVersion: 1,
    id: "openburnbar-linux-p28-installed-smarthub-session-v1",
    requirementId: "P-28",
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
  validateP28InstalledSession(document, {
    ...options,
    repoRoot,
    candidateRunId: String(options.candidateRunId),
  });
  const output = path.join(outputRoot, P28_SESSION_FILENAME);
  if (fs.existsSync(output) || fs.lstatSync(output, { throwIfNoEntry: false }))
    throw new Error(
      "P-28 output session already exists; refusing replay or replacement",
    );
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
    const result = materializeP28SmartHubSession(
      parseArguments(process.argv.slice(2)),
    );
    process.stdout.write(`${JSON.stringify({ output: result.output })}\n`);
  } catch (error) {
    process.stderr.write(
      `P-28 SmartHub materialization failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
