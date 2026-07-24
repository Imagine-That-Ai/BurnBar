import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P16_REQUIREMENT_ID = "P-16";
export const P16_PROOF_ROLE = "feature.cloud-devices-installed";
export const P16_PROOF_FILENAME = "p16-installed-cloud-devices-proof.json";
export const P16_SESSION_FILENAME = "p16-installed-cloud-devices-session.json";
export const P16_STATES = Object.freeze([
  "pending",
  "approved",
  "revoked",
  "degraded",
  "recovered",
]);
export const P16_RAW_FILES = Object.freeze([
  "cloud-devices-coordination-request.json",
  "cloud-devices-revocation-ready.json",
  "cloud-devices-marker.json",
  "cloud-devices-native-transcript.json",
  "cloud-devices-mobile-receipt.json",
  ...P16_STATES.flatMap((state) => [
    `cloud-devices-${state}.png`,
    `cloud-devices-${state}-atspi.json`,
  ]),
]);

const MARKER = /^p16-[a-f0-9]{16}$/u;
const SHA = /^[a-f0-9]{64}$/u;
const DEVICE_HASH = /^sha256:[a-f0-9]{64}$/u;
const FINGERPRINT_HASH = /^sha256:[a-f0-9]{64}$/u;

function fail(message) {
  throw new Error(message);
}
function instant(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`);
  return parsed;
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P16_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}

function validateMarker(value, expected, binding) {
  exactKeys(
    value,
    ["challenge", "installed", "marker", "nonce", "package", "producer"],
    "P-16 marker",
  );
  if (
    value.producer !== "openburnbar-p16-installed-cloud-devices-probe-v1" ||
    !MARKER.test(value.marker ?? "") ||
    !/^[a-f0-9]{32}$/u.test(value.nonce ?? "") ||
    !SHA.test(value.challenge ?? "")
  )
    fail("P-16 marker identity is invalid");
  exactKeys(
    value.installed,
    ["daemon", "desktop", "packageName", "packageOwned"],
    "P-16 installed identity",
  );
  const expectedPackage =
    expected.format === "arch" ? "openburnbar" : "open-burn-bar";
  if (
    value.installed.daemon !== "/usr/bin/openburnbar-daemon" ||
    value.installed.desktop !== "/usr/bin/openburnbar-linux-desktop" ||
    value.installed.packageName !== expectedPackage ||
    value.installed.packageOwned !== true
  )
    fail("P-16 installed identity is substituted");
  exactKeys(
    value.package,
    ["architecture", "format", "manifestSha256", "version"],
    "P-16 marker package",
  );
  if (
    value.package.architecture !== expected.architecture ||
    value.package.format !== expected.format ||
    value.package.version !== binding.packageVersion ||
    value.package.manifestSha256 !== binding.manifestSha256
  )
    fail("P-16 marker package binding is invalid");
  const expectedChallenge = crypto
    .createHash("sha256")
    .update(
      [
        binding.targetHead,
        String(binding.candidateRunId),
        binding.candidateArtifactDigest,
        value.marker,
        value.nonce,
      ].join("\n"),
    )
    .digest("hex");
  if (value.challenge !== expectedChallenge)
    fail("P-16 marker challenge is not candidate-bound");
}

function validateMobileReceipt(value, marker, envelope) {
  exactKeys(
    value,
    [
      "candidate",
      "capturedAt",
      "events",
      "linux",
      "physicalDevice",
      "producer",
      "restoration",
      "targetHead",
    ],
    "P-16 physical-device receipt",
  );
  if (
    value.producer !== "openburnbar-p16-physical-ipad-trust-cycle-v1" ||
    value.targetHead !== envelope.document.targetHead ||
    String(value.candidate?.runId) !==
      String(envelope.document.candidate.runId) ||
    value.candidate?.artifactDigest !==
      envelope.document.candidate.artifactDigest
  )
    fail("P-16 physical-device receipt is not candidate-bound");
  const captured = instant(value.capturedAt, "P-16 physical-device receipt");
  if (captured < envelope.startedAt || captured > envelope.endedAt)
    fail("P-16 physical-device receipt is outside the live session");
  exactKeys(
    value.physicalDevice,
    [
      "appCheckAttested",
      "bundleIdentifier",
      "deviceIdentifierHash",
      "platform",
      "simulator",
    ],
    "P-16 physical device",
  );
  if (
    value.physicalDevice.platform !== "iPadOS" ||
    value.physicalDevice.simulator !== false ||
    value.physicalDevice.bundleIdentifier !== "com.openburnbar.app" ||
    value.physicalDevice.appCheckAttested !== true ||
    !DEVICE_HASH.test(value.physicalDevice.deviceIdentifierHash ?? "")
  )
    fail("P-16 receipt is not from an App-Check-attested physical iPad");
  exactKeys(
    value.linux,
    ["deviceIdHash", "marker", "safetyFingerprintHash"],
    "P-16 receipt Linux identity",
  );
  if (
    value.linux.marker !== marker.marker ||
    !DEVICE_HASH.test(value.linux.deviceIdHash ?? "") ||
    !FINGERPRINT_HASH.test(value.linux.safetyFingerprintHash ?? "")
  )
    fail("P-16 mobile receipt does not bind the Linux identity");
  const expected = [
    [1, "list", "listLinuxAppCheckDevices", "pending", false],
    [2, "approve", "approveLinuxAppCheckDevice", "approved", true],
    [3, "list", "listLinuxAppCheckDevices", "approved", false],
    [4, "revoke", "revokeLinuxAppCheckDevice", "revoked", true],
    [5, "list", "listLinuxAppCheckDevices", "revoked", false],
  ];
  if (!Array.isArray(value.events) || value.events.length !== expected.length)
    fail("P-16 physical-device trust cycle is incomplete");
  let previousObserved = 0;
  const actionNonces = new Set();
  const actionProofs = new Set();
  value.events.forEach((event, index) => {
    exactKeys(
      event,
      [
        "action",
        "actionNonceHash",
        "callable",
        "nonceBound",
        "observedAt",
        "sequence",
        "signedActionProof",
        "signedActionProofHash",
        "state",
      ],
      `P-16 mobile event ${index + 1}`,
    );
    const row = expected[index];
    const observed = instant(
      event.observedAt,
      `P-16 mobile event ${index + 1}`,
    );
    const isAction = row[4];
    if (
      event.sequence !== row[0] ||
      event.action !== row[1] ||
      event.callable !== row[2] ||
      event.state !== row[3] ||
      event.nonceBound !== row[4] ||
      event.signedActionProof !== row[4] ||
      (isAction
        ? !DEVICE_HASH.test(event.actionNonceHash ?? "") ||
          !DEVICE_HASH.test(event.signedActionProofHash ?? "")
        : event.actionNonceHash !== null ||
          event.signedActionProofHash !== null) ||
      observed < envelope.startedAt ||
      observed > envelope.endedAt ||
      observed < previousObserved
    )
      fail(`P-16 mobile event ${index + 1} is invalid`);
    previousObserved = observed;
    if (isAction) {
      actionNonces.add(event.actionNonceHash);
      actionProofs.add(event.signedActionProofHash);
    }
  });
  if (actionNonces.size !== 2 || actionProofs.size !== 2)
    fail("P-16 physical-device action nonce or proof was replayed");
  exactKeys(
    value.restoration,
    ["createdDeviceRevoked", "noPendingMutation", "trustedDeviceStateRestored"],
    "P-16 mobile restoration",
  );
  if (
    value.restoration.createdDeviceRevoked !== true ||
    value.restoration.noPendingMutation !== true ||
    value.restoration.trustedDeviceStateRestored !== true
  )
    fail("P-16 physical-device trust state was not restored");
  return value;
}

function validateCoordinationRequest(value, marker, envelope) {
  exactKeys(
    value,
    ["candidate", "challenge", "linux", "marker", "producer", "requestedAt", "targetHead"],
    "P-16 coordination request",
  );
  exactKeys(value.candidate, ["artifactDigest", "runId"], "P-16 coordination candidate");
  exactKeys(value.linux, ["deviceIdHash", "safetyFingerprintHash"], "P-16 coordination Linux identity");
  const requestedAt = instant(value.requestedAt, "P-16 coordination request");
  if (
    value.producer !== "openburnbar-p16-linux-trust-cycle-request-v1" ||
    value.targetHead !== envelope.document.targetHead ||
    String(value.candidate.runId) !== String(envelope.document.candidate.runId) ||
    value.candidate.artifactDigest !== envelope.document.candidate.artifactDigest ||
    value.marker !== marker.marker || value.challenge !== marker.challenge ||
    !DEVICE_HASH.test(value.linux.deviceIdHash ?? "") ||
    !FINGERPRINT_HASH.test(value.linux.safetyFingerprintHash ?? "") ||
    requestedAt < envelope.startedAt || requestedAt > envelope.endedAt
  ) fail("P-16 coordination request is stale or unbound");
  return value;
}

function validateRevocationReady(value, request, envelope) {
  exactKeys(
    value,
    ["approvedStateObserved", "candidate", "challenge", "linux", "marker", "observedAt", "producer", "restartPersistenceObserved", "targetHead"],
    "P-16 revocation-ready acknowledgement",
  );
  const observedAt = instant(value.observedAt, "P-16 revocation-ready acknowledgement");
  if (
    value.producer !== "openburnbar-p16-linux-revoke-ready-v1" ||
    value.approvedStateObserved !== true || value.restartPersistenceObserved !== true ||
    value.targetHead !== request.targetHead || value.marker !== request.marker ||
    value.challenge !== request.challenge ||
    JSON.stringify(value.candidate) !== JSON.stringify(request.candidate) ||
    JSON.stringify(value.linux) !== JSON.stringify(request.linux) ||
    observedAt < envelope.startedAt || observedAt > envelope.endedAt
  ) fail("P-16 revocation-ready acknowledgement is stale or unbound");
  return value;
}

function validateStatus(value, label, expectedState) {
  exactKeys(
    value,
    [
      "deviceApprovalRequired",
      "deviceIdHash",
      "phase",
      "safetyFingerprintHash",
      "signedIn",
      "state",
      "syncState",
    ],
    label,
  );
  if (
    value.state !== expectedState ||
    !["signed-out", "authorizing", "active", "unavailable"].includes(
      value.state,
    ) ||
    typeof value.phase !== "string" ||
    typeof value.signedIn !== "boolean" ||
    typeof value.deviceApprovalRequired !== "boolean" ||
    !["local-only", "cloud-ready"].includes(value.syncState) ||
    !DEVICE_HASH.test(value.deviceIdHash ?? "") ||
    !FINGERPRINT_HASH.test(value.safetyFingerprintHash ?? "")
  )
    fail(`${label} is invalid or leaks an unredacted device identity`);
}

function validateNative(value, marker, envelope, mobileSha256, mobileIdentity) {
  exactKeys(
    value,
    [
      "account",
      "challenge",
      "degradation",
      "endedAt",
      "marker",
      "mobile",
      "producer",
      "restoration",
      "startedAt",
    ],
    "P-16 native transcript",
  );
  const startedAt = instant(value.startedAt, "P-16 transcript start");
  const endedAt = instant(value.endedAt, "P-16 transcript end");
  if (
    startedAt < envelope.startedAt ||
    endedAt > envelope.endedAt ||
    endedAt <= startedAt ||
    value.producer !== marker.producer ||
    value.marker !== marker.marker ||
    value.challenge !== marker.challenge
  )
    fail("P-16 native transcript is stale or unbound");
  exactKeys(
    value.account,
    ["approved", "pending", "recovered", "restarted", "revoked"],
    "P-16 account states",
  );
  validateStatus(value.account.pending, "P-16 pending state", "authorizing");
  validateStatus(value.account.approved, "P-16 approved state", "active");
  validateStatus(value.account.revoked, "P-16 revoked state", "unavailable");
  validateStatus(value.account.recovered, "P-16 recovered state", "active");
  validateStatus(value.account.restarted, "P-16 restarted state", "active");
  if (
    value.account.pending.deviceApprovalRequired !== true ||
    value.account.pending.signedIn !== true ||
    value.account.approved.signedIn !== true ||
    value.account.approved.syncState !== "cloud-ready" ||
    value.account.revoked.signedIn !== true ||
    value.account.revoked.syncState !== "local-only" ||
    value.account.revoked.deviceApprovalRequired !== false ||
    JSON.stringify(value.account.recovered) !==
      JSON.stringify(value.account.restarted)
  )
    fail(
      "P-16 account approval, revocation, or restart lifecycle is incomplete",
    );
  for (const status of Object.values(value.account)) {
    if (
      status.deviceIdHash !== mobileIdentity.deviceIdHash ||
      status.safetyFingerprintHash !== mobileIdentity.safetyFingerprintHash
    )
      fail(
        "P-16 Linux account state is not bound to the physical-device receipt",
      );
  }
  exactKeys(
    value.mobile,
    ["approvalAuthority", "callables", "receiptSha256"],
    "P-16 mobile binding",
  );
  if (
    value.mobile.approvalAuthority !== "physical-ipad" ||
    value.mobile.receiptSha256 !== mobileSha256 ||
    JSON.stringify(value.mobile.callables) !==
      JSON.stringify([
        "listLinuxAppCheckDevices",
        "approveLinuxAppCheckDevice",
        "revokeLinuxAppCheckDevice",
      ])
  )
    fail("P-16 native transcript substitutes the trusted-device authority");
  exactKeys(
    value.degradation,
    [
      "daemonStopped",
      "errorVisible",
      "optimisticSuccess",
      "recovered",
      "restartPersistent",
    ],
    "P-16 degradation",
  );
  if (
    value.degradation.daemonStopped !== true ||
    value.degradation.errorVisible !== true ||
    value.degradation.optimisticSuccess !== false ||
    value.degradation.recovered !== true ||
    value.degradation.restartPersistent !== true
  )
    fail("P-16 degraded/recovery evidence is incomplete");
  exactKeys(
    value.restoration,
    [
      "cloudDevicesRestored",
      "daemonActiveAfter",
      "daemonActiveBefore",
      "desktopPidsAfter",
      "desktopPidsBefore",
      "isolatedStateRestored",
      "noSecretsRecorded",
    ],
    "P-16 restoration",
  );
  if (
    value.restoration.cloudDevicesRestored !== true ||
    value.restoration.daemonActiveAfter !==
      value.restoration.daemonActiveBefore ||
    JSON.stringify(value.restoration.desktopPidsAfter) !==
      JSON.stringify(value.restoration.desktopPidsBefore) ||
    value.restoration.isolatedStateRestored !== true ||
    value.restoration.noSecretsRecorded !== true
  )
    fail("P-16 local or cloud state was not restored");
  const serialized = JSON.stringify(value);
  if (
    /refresh[_-]?token|firebase[_-]?id[_-]?token|app[_-]?check[_-]?token|private[_-]?key|bearer\s/iu.test(
      serialized,
    )
  )
    fail("P-16 transcript leaks authentication material");
  return { startedAt, endedAt };
}

function validateA11y(snapshot, label, expectedRoute, startedAt, endedAt) {
  const value = parseJson(snapshot.bytes, label);
  exactKeys(
    value,
    [
      "application",
      "capturedAt",
      "focusedName",
      "namedNodes",
      "producer",
      "route",
      "statusText",
    ],
    label,
  );
  const captured = instant(value.capturedAt, `${label} capture`);
  if (
    value.application !== "OpenBurnBar" ||
    value.producer !== "openburnbar-p16-atspi-live-v1" ||
    value.route !== "account" ||
    typeof value.focusedName !== "string" ||
    typeof value.statusText !== "string" ||
    !expectedRoute.test(`${value.focusedName} ${value.statusText}`) ||
    !Array.isArray(value.namedNodes) ||
    value.namedNodes.length < 6 ||
    captured < startedAt ||
    captured > endedAt
  )
    fail(`${label} does not prove its live account state`);
}

export function validateP16InstalledSession(document, binding) {
  const repoRoot = binding.repoRoot;
  if (
    document.id !== "openburnbar-linux-p16-installed-cloud-devices-session-v1"
  )
    fail("P-16 session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P16_REQUIREMENT_ID,
    "P-16 installed session",
  );
  validateMarker(document.marker, envelope.expected, binding);
  const evidenceKeys = [
    "coordinationRequest",
    "mobileReceipt",
    "nativeTranscript",
    "revocationReady",
    ...P16_STATES.flatMap((state) => [
      `${state}Screenshot`,
      `${state}Accessibility`,
    ]),
  ];
  exactKeys(document.evidence, evidenceKeys, "P-16 evidence");
  const coordination = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.coordinationRequest,
    "P-16 coordination request",
    { mediaType: "json", minimumBytes: 400 },
  );
  const coordinationDocument = validateCoordinationRequest(
    parseJson(coordination.bytes, "P-16 coordination request"),
    document.marker,
    { ...envelope, document },
  );
  const revocationReady = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.revocationReady,
    "P-16 revocation-ready acknowledgement",
    { mediaType: "json", minimumBytes: 450 },
  );
  validateRevocationReady(
    parseJson(revocationReady.bytes, "P-16 revocation-ready acknowledgement"),
    coordinationDocument,
    envelope,
  );
  const mobile = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.mobileReceipt,
    "P-16 physical-device receipt",
    { mediaType: "json", minimumBytes: 800 },
  );
  const mobileDocument = validateMobileReceipt(
    parseJson(mobile.bytes, "P-16 physical-device receipt"),
    document.marker,
    { ...envelope, document },
  );
  if (
    mobileDocument.linux.deviceIdHash !== coordinationDocument.linux.deviceIdHash ||
    mobileDocument.linux.safetyFingerprintHash !== coordinationDocument.linux.safetyFingerprintHash
  ) fail("P-16 mobile receipt targets another coordination request");
  const native = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.nativeTranscript,
    "P-16 native transcript",
    { mediaType: "json", minimumBytes: 1200 },
  );
  const timing = validateNative(
    parseJson(native.bytes, "P-16 native transcript"),
    document.marker,
    envelope,
    mobile.sha256,
    mobileDocument.linux,
  );
  const pixelHashes = new Set();
  const patterns = [
    /pending|approval/iu,
    /approved|cloud-ready|connected/iu,
    /revoked|rejected|unavailable/iu,
    /daemon unavailable|offline|error/iu,
    /recovered|connected|cloud-ready/iu,
  ];
  P16_STATES.forEach((state, index) => {
    const screenshot = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[`${state}Screenshot`],
      `P-16 ${state} screenshot`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(screenshot.bytes, `P-16 ${state} screenshot`);
    if (png.nonBlankPixelRatio < 0.05)
      fail(`P-16 ${state} screenshot is blank`);
    pixelHashes.add(
      crypto.createHash("sha256").update(png.pixels).digest("hex"),
    );
    const accessibility = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[`${state}Accessibility`],
      `P-16 ${state} accessibility`,
      { mediaType: "json", minimumBytes: 300 },
    );
    validateA11y(
      accessibility,
      `P-16 ${state} accessibility`,
      patterns[index],
      timing.startedAt,
      timing.endedAt,
    );
  });
  if (pixelHashes.size !== P16_STATES.length)
    fail("P-16 screenshots are replayed across states");
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((entry) => entry.path)).size !== evidence.length)
    fail("P-16 reuses an evidence artifact");
  return { document, evidence, endedAt: timing.endedAt };
}

export function buildP16Proof({ session, source, collectedAt }) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p16-cloud-devices-proof-v1",
    requirementId: P16_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    package: {
      architecture: session.package.architecture,
      format: session.package.format,
      version: session.package.version,
    },
    collectedAt,
    source: { method: "live-installed-cloud-devices-session", ...source },
    claim: {
      candidateBound: true,
      daemonAuthoritativeAccount: true,
      exactRestoration: true,
      physicalIPadAuthority: true,
      redactedIdentity: true,
      restartPersistence: true,
      trustedDeviceApprovalRevocation: true,
      unavailableRecovery: true,
    },
  };
}

export function validateP16Proof({
  snapshot,
  repoRoot,
  targetHead,
  environmentId,
  candidateRunId,
  candidateArtifactDigest,
  packageVersion,
  manifestSha256,
  manifestSignatureSha256,
}) {
  const value = parseJson(snapshot.bytes, "P-16 proof");
  exactKeys(
    value,
    [
      "candidate",
      "claim",
      "collectedAt",
      "environmentId",
      "id",
      "package",
      "requirementId",
      "schemaVersion",
      "source",
      "targetHead",
    ],
    "P-16 proof",
  );
  if (
    value.schemaVersion !== 1 ||
    value.id !== "openburnbar-linux-p16-cloud-devices-proof-v1" ||
    value.requirementId !== P16_REQUIREMENT_ID ||
    value.targetHead !== targetHead ||
    value.environmentId !== environmentId ||
    String(value.candidate?.runId) !== String(candidateRunId) ||
    value.candidate?.artifactDigest !== candidateArtifactDigest
  )
    fail("P-16 proof binding is invalid");
  exactKeys(
    value.package,
    ["architecture", "format", "version"],
    "P-16 proof package",
  );
  exactKeys(
    value.claim,
    [
      "candidateBound",
      "daemonAuthoritativeAccount",
      "exactRestoration",
      "physicalIPadAuthority",
      "redactedIdentity",
      "restartPersistence",
      "trustedDeviceApprovalRevocation",
      "unavailableRecovery",
    ],
    "P-16 proof claim",
  );
  if (!Object.values(value.claim).every((item) => item === true))
    fail("P-16 proof claim is incomplete");
  exactKeys(
    value.source,
    ["method", "path", "sha256", "size"],
    "P-16 proof source",
  );
  if (value.source.method !== "live-installed-cloud-devices-session")
    fail("P-16 proof source is not live");
  const source = artifact(
    repoRoot,
    environmentId,
    {
      path: value.source.path,
      sha256: value.source.sha256,
      size: value.source.size,
    },
    "P-16 session source",
    { mediaType: "json", minimumBytes: 1200 },
  );
  const sourceDocument = parseJson(source.bytes, "P-16 source session");
  const validated = validateP16InstalledSession(sourceDocument, {
    repoRoot,
    targetHead,
    environmentId,
    candidateRunId,
    candidateArtifactDigest,
    packageVersion,
    manifestSha256,
    manifestSignatureSha256,
  });
  if (
    value.package.version !== sourceDocument.package.version ||
    value.package.architecture !== sourceDocument.package.architecture ||
    value.package.format !== sourceDocument.package.format
  )
    fail("P-16 proof package does not match its source session");
  validateCollectedAt(value.collectedAt, validated.endedAt);
  return { ...value, evidence: validated.evidence };
}
