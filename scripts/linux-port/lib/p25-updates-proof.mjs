import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P25_REQUIREMENT_ID = "P-25";
export const P25_PROOF_ROLE = "feature.updates-installed";
export const P25_PROOF_FILENAME = "p25-installed-updates-proof.json";
export const P25_SESSION_FILENAME = "p25-installed-updates-session.json";
const PHASES = ["available", "current", "error", "restart"];
const CHANNELS = {
  deb: ["apt", "apt/dpkg"],
  rpm: ["dnf", "dnf/rpm"],
  arch: ["pacman", "pacman"],
  appimage: ["appimage", "user-managed artifact"],
};
const PACKAGE_NAMES = {
  deb: "open-burn-bar",
  rpm: "open-burn-bar",
  arch: "openburnbar",
};
const SHA256 = /^[a-f0-9]{64}$/u;
const RELEASE_COMMIT = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/u;

function fail(message) {
  throw new Error(message);
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P25_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}
function timestamp(value, label) {
  const result = Date.parse(value);
  if (!Number.isFinite(result)) fail(`${label} timestamp is invalid`);
  return result;
}
function phaseTransition(value) {
  return {
    status: value?.status,
    from: value?.fromVersion ?? value?.from,
    to: value?.toVersion ?? value?.to,
  };
}
function olderVersion(previous, candidate) {
  const semver = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
  if (!semver.test(String(previous)) || !semver.test(String(candidate)))
    return false;
  const left = String(previous).split(".").map(Number);
  const right = String(candidate).split(".").map(Number);
  if (
    left.length !== 3 ||
    right.length !== 3 ||
    [...left, ...right].some((part) => !Number.isSafeInteger(part) || part < 0)
  )
    return false;
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] < right[index];
  }
  return false;
}
function preservationValid(value) {
  if (value?.status !== "passed") return false;
  const hashes = [
    value.sha256,
    value.sentinelSha256,
    value.afterPreviousSha256,
    value.afterUpdateSha256,
    value.afterRollbackSha256,
    value.afterRestoreSha256,
  ].filter(Boolean);
  return (
    hashes.length >= 1 &&
    new Set(hashes).size === 1 &&
    /^[a-f0-9]{64}$/u.test(hashes[0])
  );
}

function validateFileRecord(value, label) {
  exactKeys(value, ["file", "sha256", "size"], label);
  if (
    typeof value.file !== "string" ||
    value.file.length === 0 ||
    value.file.includes("/") ||
    value.file.includes("\\") ||
    !SHA256.test(value.sha256) ||
    !Number.isSafeInteger(value.size) ||
    value.size <= 0
  )
    fail(`${label} is invalid`);
}

function validateRelease(value, label, marker, document, candidate) {
  const keys = [
    "manifest",
    "manifestSignature",
    "metadata",
    "package",
    "releaseCommit",
    "version",
  ];
  if (!candidate) keys.push("releaseTag");
  exactKeys(value, keys, `P-25 ${label} release`);
  for (const [name, record] of [
    ["package", value.package],
    ["manifest", value.manifest],
    ["manifest signature", value.manifestSignature],
  ])
    validateFileRecord(record, `P-25 ${label} ${name}`);
  exactKeys(
    value.metadata,
    ["architecture", "name", "version"],
    `P-25 ${label} package metadata`,
  );
  if (
    value.version !==
      (candidate ? marker.candidateVersion : marker.previousVersion) ||
    value.metadata.version !== value.version ||
    value.metadata.name !== PACKAGE_NAMES[marker.packageChannel] ||
    typeof value.metadata.architecture !== "string" ||
    value.metadata.architecture.length === 0 ||
    !RELEASE_COMMIT.test(value.releaseCommit)
  )
    fail(`P-25 ${label} authenticated release identity is invalid`);
  if (candidate) {
    if (
      value.releaseCommit !== marker.targetHead ||
      value.manifest.sha256 !== document.package.manifest.sha256 ||
      value.manifestSignature.sha256 !== document.package.signature.sha256
    )
      fail(
        "P-25 candidate release provenance is not bound to the installed session",
      );
  } else if (value.releaseTag !== `linux-v${marker.previousVersion}`)
    fail("P-25 previous release tag is not version-bound");
}

function expectedCommand(channel, phase, file) {
  if (channel === "deb")
    return [
      "sudo",
      "apt-get",
      "install",
      "-y",
      "--reinstall",
      ...(["install-previous", "rollback-previous"].includes(phase)
        ? ["--allow-downgrades"]
        : []),
      file,
    ];
  if (channel === "rpm")
    return [
      "sudo",
      "dnf",
      ["install-previous", "rollback-previous"].includes(phase)
        ? "downgrade"
        : "install",
      "-y",
      file,
    ];
  return ["sudo", "pacman", "-U", "--noconfirm", file];
}

function validateLifecycle(snapshot, document) {
  const value = parseJson(snapshot.bytes, "P-25 package lifecycle");
  const marker = document.marker;
  exactKeys(
    value,
    [
      "architecture",
      "candidate",
      "candidateArtifactDigest",
      "candidateRunId",
      "commands",
      "environmentId",
      "lifecycle",
      "manager",
      "networkOutage",
      "packageChannel",
      "packageName",
      "passed",
      "previous",
      "producer",
      "restoration",
      "restoredCandidate",
      "schemaVersion",
      "targetHead",
    ],
    "P-25 package lifecycle",
  );
  if (
    value.schemaVersion !== 1 ||
    value.producer !== "openburnbar-p25-native-package-lifecycle-v1" ||
    value?.passed !== true ||
    value.targetHead !== marker.targetHead ||
    value.candidateRunId !== marker.candidateRunId ||
    value.candidateArtifactDigest !== marker.candidateArtifactDigest ||
    value.environmentId !== document.environmentId ||
    value.architecture !== document.package.architecture ||
    value.packageChannel !== marker.packageChannel ||
    value.manager !== CHANNELS[marker.packageChannel][0] ||
    value.packageName !== PACKAGE_NAMES[marker.packageChannel]
  )
    fail(
      "P-25 package lifecycle is not candidate, environment, or channel bound",
    );
  validateRelease(value.candidate, "candidate", marker, document, true);
  validateRelease(value.previous, "previous", marker, document, false);
  if (
    value.previous.metadata.architecture !==
    value.candidate.metadata.architecture
  )
    fail("P-25 previous and candidate native package architectures differ");
  if (!Array.isArray(value.commands) || value.commands.length !== 4)
    fail(
      "P-25 lifecycle must contain exactly four native package-manager commands",
    );
  const commandPhases = [
    ["install-previous", value.previous],
    ["update-candidate", value.candidate],
    ["rollback-previous", value.previous],
    ["restore-candidate", value.candidate],
  ];
  commandPhases.forEach(([phase, release], index) => {
    const row = value.commands[index];
    exactKeys(
      row,
      [
        "command",
        "exitCode",
        "installedManifestSha256",
        "installedManifestSignatureSha256",
        "installedVersion",
        "packageSha256",
        "phase",
      ],
      `P-25 ${phase} command`,
    );
    if (
      row.phase !== phase ||
      row.exitCode !== 0 ||
      row.installedVersion !== release.version ||
      row.packageSha256 !== release.package.sha256 ||
      row.installedManifestSha256 !== release.manifest.sha256 ||
      row.installedManifestSignatureSha256 !==
        release.manifestSignature.sha256 ||
      JSON.stringify(row.command) !==
        JSON.stringify(
          expectedCommand(marker.packageChannel, phase, release.package.file),
        )
    )
      fail(`P-25 ${phase} native package-manager receipt is invalid`);
  });
  exactKeys(
    value.networkOutage,
    [
      "endpoint",
      "exactPriorStateRestored",
      "method",
      "priorEnvironment",
      "restoredEnvironment",
      "systemNetworkMutated",
    ],
    "P-25 network outage",
  );
  exactKeys(
    value.networkOutage.priorEnvironment,
    ["HTTPS_PROXY", "https_proxy"],
    "P-25 prior proxy environment",
  );
  exactKeys(
    value.networkOutage.restoredEnvironment,
    ["HTTPS_PROXY", "https_proxy"],
    "P-25 restored proxy environment",
  );
  if (
    value.networkOutage.method !== "process-local-invalid-https-proxy" ||
    value.networkOutage.endpoint !== "127.0.0.1:9" ||
    value.networkOutage.systemNetworkMutated !== false ||
    value.networkOutage.exactPriorStateRestored !== true ||
    JSON.stringify(value.networkOutage.priorEnvironment) !==
      JSON.stringify(value.networkOutage.restoredEnvironment)
  )
    fail(
      "P-25 controlled outage did not restore the exact prior network environment",
    );
  const update = phaseTransition(value.lifecycle.update);
  const rollback = phaseTransition(value.lifecycle.rollback);
  if (
    update.status !== "passed" ||
    update.from !== marker.previousVersion ||
    update.to !== marker.candidateVersion ||
    rollback.status !== "passed" ||
    rollback.from !== marker.candidateVersion ||
    rollback.to !== marker.previousVersion ||
    !preservationValid(value.lifecycle.dataPreservation)
  )
    fail(
      "P-25 package lifecycle does not prove update, rollback, restore, and data preservation",
    );
  if (value.restoredCandidate !== true)
    fail("P-25 lifecycle did not restore the exact candidate after rollback");
  exactKeys(
    value.restoration,
    [
      "candidatePackageSha256",
      "installedManifestSha256",
      "installedManifestSignatureSha256",
      "installedVersion",
      "status",
    ],
    "P-25 restoration",
  );
  if (
    value.restoration.status !== "passed" ||
    value.restoration.installedVersion !== marker.candidateVersion ||
    value.restoration.candidatePackageSha256 !==
      value.candidate.package.sha256 ||
    value.restoration.installedManifestSha256 !==
      value.candidate.manifest.sha256 ||
    value.restoration.installedManifestSignatureSha256 !==
      value.candidate.manifestSignature.sha256
  )
    fail("P-25 exact candidate restoration receipt is invalid");
  return value;
}

function validatePhase(
  snapshot,
  marker,
  lifecycle,
  phase,
  captureStart,
  captureEnd,
) {
  const value = parseJson(snapshot.bytes, `P-25 ${phase} phase`);
  exactKeys(
    value,
    [
      "action",
      "advertisedVersion",
      "appPid",
      "candidateArtifactDigest",
      "candidateRunId",
      "capturedAt",
      "expectedVersion",
      "manifestSha256",
      "observed",
      "package",
      "packageVersion",
      "phase",
      "provenance",
      "producer",
      "rollbackClaimed",
      "schemaVersion",
      "targetHead",
    ],
    `P-25 ${phase} phase`,
  );
  if (
    value.schemaVersion !== 1 ||
    value.producer !== "openburnbar-p25-installed-update-phase-v1" ||
    value.phase !== phase ||
    value.targetHead !== marker.targetHead ||
    value.candidateRunId !== marker.candidateRunId ||
    value.candidateArtifactDigest !== marker.candidateArtifactDigest ||
    value.manifestSha256 !== marker.manifestSha256 ||
    value.packageVersion !== marker.candidateVersion ||
    value.advertisedVersion !==
      (phase === "available" ? marker.candidateVersion : null) ||
    value.rollbackClaimed !== false ||
    !Number.isSafeInteger(value.appPid) ||
    value.appPid <= 1
  )
    fail(`P-25 ${phase} phase binding is invalid`);
  const expected =
    phase === "available" ? marker.previousVersion : marker.candidateVersion;
  const channel = CHANNELS[marker.packageChannel];
  if (
    value.expectedVersion !== expected ||
    value.package?.channel !== marker.packageChannel ||
    value.package.version !== expected ||
    value.package.manager !== channel[0] ||
    value.package.owner !== channel[1]
  )
    fail(`P-25 ${phase} package identity is invalid`);
  exactKeys(
    value.provenance,
    [
      "manifestSha256",
      "manifestSignatureSha256",
      "packageSha256",
      "releaseCommit",
    ],
    `P-25 ${phase} provenance`,
  );
  const release =
    phase === "available" ? lifecycle.previous : lifecycle.candidate;
  if (
    value.provenance.packageSha256 !== release.package.sha256 ||
    value.provenance.manifestSha256 !== release.manifest.sha256 ||
    value.provenance.manifestSignatureSha256 !==
      release.manifestSignature.sha256 ||
    value.provenance.releaseCommit !== release.releaseCommit
  )
    fail(
      `P-25 ${phase} phase is not bound to the authenticated installed package`,
    );
  const at = timestamp(value.capturedAt, `P-25 ${phase}`);
  if (at < captureStart || at > captureEnd)
    fail(`P-25 ${phase} is outside the installed session`);
  const common = [
    "updates",
    "packageChannel",
    "owner",
    "shellVersion",
    "daemonVersion",
  ];
  const required =
    phase === "available"
      ? [
          ...common,
          "available",
          "targetVersion",
          "verified",
          "fresh",
          "signedDownloadEnabled",
          "safeActionActivated",
          "shellDoesNotInstall",
        ]
      : phase === "current"
        ? [
            ...common,
            "current",
            "verified",
            "fresh",
            "noDownloadAction",
            "shellDoesNotInstall",
          ]
        : phase === "error"
          ? [
              ...common,
              "error",
              "noEnabledDownload",
              "noEnabledInstall",
              "recovery",
            ]
          : [...common, "restarted", "guidance", "daemonAligned"];
  exactKeys(value.observed, required, `P-25 ${phase} observations`);
  if (required.some((key) => value.observed[key] !== true))
    fail(`P-25 ${phase} did not prove required native UI state`);
  if (phase === "available") {
    exactKeys(
      value.action,
      ["activated", "kind", "packageMutation"],
      "P-25 update action",
    );
    if (
      value.action.kind !== "open-signed-download" ||
      value.action.activated !== true ||
      value.action.packageMutation !== false
    )
      fail("P-25 native update action is unsafe or unproven");
  } else if (value.action !== null)
    fail(`P-25 ${phase} unexpectedly records a package action`);
  return { at, value };
}

export function validateP25InstalledSession(
  document,
  binding,
  { repoRoot = binding.repoRoot } = {},
) {
  exactKeys(
    document,
    [
      "candidate",
      "capture",
      "desktop",
      "environmentId",
      "evidence",
      "id",
      "marker",
      "package",
      "requirementId",
      "schemaVersion",
      "targetHead",
    ],
    "P-25 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p25-installed-updates-session-v1"
  )
    fail("P-25 installed session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P25_REQUIREMENT_ID,
    "P-25 installed session",
  );
  exactKeys(
    document.marker,
    [
      "candidateArtifactDigest",
      "candidateRunId",
      "candidateVersion",
      "manifestSha256",
      "packageChannel",
      "previousVersion",
      "targetHead",
    ],
    "P-25 marker",
  );
  if (
    document.marker.targetHead !== document.targetHead ||
    document.marker.candidateRunId !== String(document.candidate.runId) ||
    document.marker.candidateArtifactDigest !==
      document.candidate.artifactDigest ||
    document.marker.candidateVersion !== document.package.version ||
    document.marker.manifestSha256 !== document.package.manifest.sha256 ||
    !CHANNELS[document.marker.packageChannel] ||
    document.marker.packageChannel !== document.package.format ||
    !olderVersion(
      document.marker.previousVersion,
      document.marker.candidateVersion,
    )
  )
    fail("P-25 marker is not candidate-bound");
  exactKeys(
    document.evidence,
    [
      "availablePhase",
      "availableScreenshot",
      "currentPhase",
      "currentScreenshot",
      "errorPhase",
      "errorScreenshot",
      "lifecycle",
      "restartPhase",
      "restartScreenshot",
    ],
    "P-25 evidence",
  );
  const lifecycle = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.lifecycle,
    "P-25 package lifecycle",
    { mediaType: "json", minimumBytes: 300 },
  );
  const lifecycleDocument = validateLifecycle(lifecycle, document);
  const captures = [];
  const hashes = new Set();
  for (const phase of PHASES) {
    const phaseRecord = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[`${phase}Phase`],
      `P-25 ${phase} phase`,
      { mediaType: "json", minimumBytes: 500 },
    );
    captures.push(
      validatePhase(
        phaseRecord,
        document.marker,
        lifecycleDocument,
        phase,
        envelope.startedAt,
        envelope.endedAt,
      ),
    );
    const screenshot = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[`${phase}Screenshot`],
      `P-25 ${phase} screenshot`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(screenshot.bytes, `P-25 ${phase} screenshot`);
    if (png.nonBlankPixelRatio < 0.05)
      fail(`P-25 ${phase} screenshot is blank`);
    hashes.add(crypto.createHash("sha256").update(png.pixels).digest("hex"));
  }
  if (
    captures.some(
      (row, index) => index > 0 && row.at <= captures[index - 1].at,
    ) ||
    hashes.size !== PHASES.length
  )
    fail("P-25 captures are out of order or replayed");
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((row) => row.path)).size !== evidence.length)
    fail("P-25 reuses an evidence artifact");
  return {
    document,
    evidence,
    endedAt: envelope.endedAt,
    nativeStates: 4,
    safeActions: 1,
    rollbackLifecycle: 1,
    lifecycleBinding: {
      architecture: lifecycleDocument.architecture,
      candidatePackageSha256: lifecycleDocument.candidate.package.sha256,
      candidateVersion: lifecycleDocument.candidate.version,
      previousPackageSha256: lifecycleDocument.previous.package.sha256,
      previousVersion: lifecycleDocument.previous.version,
    },
  };
}

export function buildP25Proof({
  session,
  source,
  collectedAt,
  nativeStates,
  safeActions,
  rollbackLifecycle,
}) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p25-updates-proof-v1",
    requirementId: P25_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: "live-installed-update-lifecycle-session", ...source },
    claim: {
      passed: true,
      nativeStates,
      safeActions,
      rollbackLifecycle,
      signedFeedAvailable: true,
      signedFeedCurrent: true,
      feedErrorFailClosed: true,
      packageChannelOwned: true,
      shellPackageMutation: false,
      nativeSignedUrlAction: true,
      realRollbackReceipt: true,
      restartPersistence: true,
      accessibleUI: true,
    },
  };
}

export function validateP25Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-25 proof");
  exactKeys(
    proof,
    [
      "candidate",
      "claim",
      "collectedAt",
      "environmentId",
      "id",
      "requirementId",
      "schemaVersion",
      "source",
      "targetHead",
    ],
    "P-25 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p25-updates-proof-v1" ||
    proof.requirementId !== P25_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate?.runId !== String(binding.candidateRunId) ||
    proof.candidate?.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-25 proof binding is invalid");
  exactKeys(
    proof.source,
    ["method", "path", "sha256", "size"],
    "P-25 proof source",
  );
  if (proof.source.method !== "live-installed-update-lifecycle-session")
    fail("P-25 proof source is not live");
  const sourceRecord = {
    path: proof.source.path,
    sha256: proof.source.sha256,
    size: proof.source.size,
  };
  const source = artifact(
    repoRoot,
    binding.environmentId,
    sourceRecord,
    "P-25 source session",
    { mediaType: "json", minimumBytes: 1000 },
  );
  const validated = validateP25InstalledSession(
    parseJson(source.bytes, "P-25 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  const booleans = [
    "accessibleUI",
    "feedErrorFailClosed",
    "nativeSignedUrlAction",
    "packageChannelOwned",
    "realRollbackReceipt",
    "restartPersistence",
    "signedFeedAvailable",
    "signedFeedCurrent",
  ];
  exactKeys(
    proof.claim,
    [
      "nativeStates",
      "passed",
      "rollbackLifecycle",
      "safeActions",
      "shellPackageMutation",
      ...booleans,
    ],
    "P-25 claim",
  );
  if (
    proof.claim.passed !== true ||
    proof.claim.nativeStates !== 4 ||
    proof.claim.nativeStates !== validated.nativeStates ||
    proof.claim.safeActions !== 1 ||
    proof.claim.rollbackLifecycle !== 1 ||
    proof.claim.shellPackageMutation !== false ||
    booleans.some((key) => proof.claim[key] !== true)
  )
    fail("P-25 proof claim is not derived from installed evidence");
  return {
    proof,
    source: sourceRecord,
    evidence: validated.evidence,
    lifecycleBinding: validated.lifecycleBinding,
  };
}
