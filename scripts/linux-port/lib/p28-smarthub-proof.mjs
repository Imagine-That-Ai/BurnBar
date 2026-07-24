import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";
import { assertInstalledManifest } from "./linux-installed-manifest.mjs";

export const P28_REQUIREMENT_ID = "P-28";
export const P28_PROOF_ROLE = "feature.smarthub-installed";
export const P28_PROOF_FILENAME = "p28-installed-smarthub-proof.json";
export const P28_SESSION_FILENAME = "p28-installed-smarthub-session.json";
export const P28_STATES = Object.freeze([
  "discovered",
  "controlled",
  "degraded",
  "recovered",
]);
export const P28_RAW_FILES = Object.freeze([
  "smarthub-marker.json",
  "smarthub-peer-manifest.json",
  "smarthub-native-transcript.json",
  ...P28_STATES.flatMap((state) => [
    `smarthub-${state}.png`,
    `smarthub-${state}-atspi.json`,
  ]),
]);

const MARKER = /^p28-[a-f0-9]{16}$/u;
const NONCE = /^[a-f0-9]{48}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const PACKAGE_MANAGER = Object.freeze({
  deb: "dpkg",
  rpm: "rpm",
  arch: "pacman",
});
const INSTALLED_PATHS = Object.freeze([
  "/usr/bin/openburnbar-cli",
  "/usr/libexec/openburnbar-daemon-launch",
  "/usr/bin/openburnbar-linux-desktop",
]);
const INVENTORY_PATHS = Object.freeze([
  "/usr/bin/openburnbar-daemon",
  ...INSTALLED_PATHS,
]);
const EXPECTED_STATUS = Object.freeze({
  controlled: "bridge_control_ok",
  degraded: "blocked_bridge_not_reachable",
  recovered: "bridge_control_ok",
});

function fail(message) {
  throw new Error(message);
}

function timestamp(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`);
  return parsed;
}

function digest(value) {
  return crypto
    .createHash("sha256")
    .update(`${JSON.stringify(value, null, 2)}\n`)
    .digest("hex");
}

function same(left, right) {
  const normalize = (value) => {
    if (Array.isArray(value)) return value.map(normalize);
    if (value && typeof value === "object") {
      return Object.fromEntries(
        Object.keys(value)
          .sort()
          .map((key) => [key, normalize(value[key])]),
      );
    }
    return value;
  };
  return JSON.stringify(normalize(left)) === JSON.stringify(normalize(right));
}

function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P28_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}

function validatePidList(value, label, { empty = false } = {}) {
  if (
    !Array.isArray(value) ||
    value.some((pid) => !Number.isSafeInteger(pid) || pid < 1) ||
    new Set(value).size !== value.length ||
    !same(
      value,
      [...value].sort((left, right) => left - right),
    ) ||
    (empty && value.length !== 0)
  ) {
    fail(`${label} process identity is invalid`);
  }
}

function validateInstalled(value, expected, label) {
  exactKeys(
    value,
    [
      "cli",
      "daemonLauncher",
      "desktop",
      "executablePackages",
      "packageManager",
      "packageName",
      "packageOwned",
    ],
    label,
  );
  exactKeys(value.executablePackages, INSTALLED_PATHS, `${label} manifest`);
  if (
    value.cli !== INSTALLED_PATHS[0] ||
    value.daemonLauncher !== INSTALLED_PATHS[1] ||
    value.desktop !== INSTALLED_PATHS[2] ||
    value.packageManager !== PACKAGE_MANAGER[expected.format] ||
    value.packageOwned !== true ||
    !/^openburnbar(?:$|[-_])/u.test(value.packageName ?? "") ||
    !INSTALLED_PATHS.every((file) =>
      /^openburnbar(?:$|[-_])/u.test(value.executablePackages[file] ?? ""),
    )
  ) {
    fail(`${label} does not identify canonical package-owned executables`);
  }
}

function validateInstalledInventory(document, binding) {
  const snapshot = artifact(
    binding.repoRoot,
    binding.environmentId,
    document.package.manifest,
    "P-28 installed package inventory",
    { mediaType: "json" },
  );
  const manifest = assertInstalledManifest(
    parseJson(snapshot.bytes, "P-28 installed package inventory"),
  );
  for (const installedPath of INVENTORY_PATHS) {
    const matches = manifest.files.filter(
      (item) => item.path === installedPath,
    );
    if (
      matches.length !== 1 ||
      matches[0].type !== "file" ||
      matches[0].uid !== 0 ||
      matches[0].gid !== 0 ||
      matches[0].mode !== "0755"
    ) {
      fail(`P-28 installed manifest omits or substitutes ${installedPath}`);
    }
  }
}

function validateProcessSnapshot(value, label) {
  exactKeys(
    value,
    ["bridgePids", "daemonActive", "daemonPids", "desktopPids"],
    label,
  );
  validatePidList(value.desktopPids, `${label} desktop`, { empty: true });
  validatePidList(value.daemonPids, `${label} daemon`);
  validatePidList(value.bridgePids, `${label} bridge`);
  if (
    value.daemonActive !== true ||
    value.daemonPids.length !== 1 ||
    value.bridgePids.length !== 1
  ) {
    fail(`${label} does not prove one live daemon and SmartHub bridge`);
  }
}

function validateMarker(value, expected) {
  exactKeys(
    value,
    [
      "installed",
      "marker",
      "nonce",
      "peerManifestSha256",
      "producer",
      "runtimeManifestSha256",
      "safety",
    ],
    "P-28 marker",
  );
  if (
    value.producer !== "openburnbar-p28-installed-marker-v1" ||
    !MARKER.test(value.marker ?? "") ||
    !NONCE.test(value.nonce ?? "") ||
    !SHA256.test(value.peerManifestSha256 ?? "") ||
    !SHA256.test(value.runtimeManifestSha256 ?? "")
  ) {
    fail("P-28 marker identity or digest binding is invalid");
  }
  validateInstalled(
    value.installed,
    expected,
    "P-28 marker installed identity",
  );
  exactKeys(
    value.safety,
    [
      "daemonServiceStateRestored",
      "exactBridgeProcessesRestored",
      "exactDesktopProcessesRestored",
      "fixtureMode",
      "isolatedHome",
      "isolatedSupport",
      "preexistingProcesses",
    ],
    "P-28 safety marker",
  );
  validateProcessSnapshot(
    value.safety.preexistingProcesses,
    "P-28 preexisting process snapshot",
  );
  if (
    value.safety.fixtureMode !== false ||
    value.safety.isolatedHome !== true ||
    value.safety.isolatedSupport !== true ||
    value.safety.daemonServiceStateRestored !== true ||
    value.safety.exactBridgeProcessesRestored !== true ||
    value.safety.exactDesktopProcessesRestored !== true
  ) {
    fail("P-28 marker reports incomplete process or service restoration");
  }
  return value;
}

function validateTxt(value, label) {
  exactKeys(
    value,
    ["daemon_version", "pairing", "platform", "protocol_version", "transport"],
    label,
  );
  if (
    value.platform !== "linux" ||
    value.pairing !== "mdns" ||
    !["unix-domain", "http"].includes(value.transport) ||
    typeof value.daemon_version !== "string" ||
    value.daemon_version.length === 0 ||
    !/^[1-9][0-9]*$/u.test(value.protocol_version ?? "")
  ) {
    fail(`${label} is incomplete or unsafe`);
  }
}

function validateDiscovery(value, instance, label) {
  if (!Array.isArray(value) || value.length !== 1) {
    fail(`${label} is absent or ambiguous`);
  }
  const row = value[0];
  const keys = Object.keys(row).sort();
  const required = [
    "adapter",
    "instances",
    "rawTranscript",
    "serviceType",
    "status",
  ];
  if (
    !required.every((key) => keys.includes(key)) ||
    keys.some((key) => ![...required, "blocker"].includes(key))
  ) {
    fail(`${label} fields are invalid`);
  }
  if (
    row.adapter !== "smart_hub_bridge" ||
    row.serviceType !== "_openburnbar-peer._tcp" ||
    row.status !== "ok" ||
    (row.blocker !== null && row.blocker !== undefined) ||
    !Array.isArray(row.instances) ||
    !row.instances.includes(instance) ||
    typeof row.rawTranscript !== "string" ||
    row.rawTranscript.length === 0
  ) {
    fail(`${label} does not prove live production SmartHub discovery`);
  }
}

function validatePeerManifest(value, marker, startedAt, endedAt) {
  exactKeys(
    value,
    [
      "advertised",
      "capturedAt",
      "daemonVersion",
      "discovery",
      "discoveryMethod",
      "marker",
      "matchedPeer",
      "nonce",
      "platform",
      "producer",
      "protocolVersion",
      "serviceType",
      "source",
      "transport",
    ],
    "P-28 peer manifest",
  );
  const capturedAt = timestamp(value.capturedAt, "P-28 peer manifest capture");
  if (
    value.producer !== "openburnbar-p28-live-peer-manifest-v1" ||
    value.marker !== marker.marker ||
    value.nonce !== marker.nonce ||
    value.serviceType !== "_openburnbar-peer._tcp" ||
    value.platform !== "linux" ||
    value.discoveryMethod !== "mdns-avahi" ||
    capturedAt < startedAt ||
    capturedAt > endedAt
  ) {
    fail(
      "P-28 peer manifest is stale, replayed, or not live Linux mDNS evidence",
    );
  }
  exactKeys(
    value.source,
    ["advertise", "browse", "discovery"],
    "P-28 peer sources",
  );
  if (
    value.source.advertise !==
      "/usr/bin/openburnbar-cli local-peer advertise-metadata --json" ||
    value.source.browse !==
      "/usr/bin/openburnbar-cli local-peer browse --json --timeout 3" ||
    value.source.discovery !==
      "/usr/bin/openburnbar-cli devices discover smarthub --json"
  ) {
    fail("P-28 peer manifest did not use the production CLI contracts");
  }
  exactKeys(
    value.advertised,
    ["instance", "service_type", "txt"],
    "P-28 advertised peer",
  );
  if (
    value.advertised.service_type !== value.serviceType ||
    !/^OpenBurnBar-/u.test(value.advertised.instance ?? "")
  ) {
    fail("P-28 advertised peer identity is invalid");
  }
  validateTxt(value.advertised.txt, "P-28 advertised TXT metadata");
  exactKeys(
    value.matchedPeer,
    ["hostName", "instanceName", "port", "txt"],
    "P-28 matched peer",
  );
  if (
    value.matchedPeer.instanceName !== value.advertised.instance ||
    typeof value.matchedPeer.hostName !== "string" ||
    value.matchedPeer.hostName.length === 0 ||
    !Number.isSafeInteger(value.matchedPeer.port) ||
    value.matchedPeer.port < 1 ||
    value.matchedPeer.port > 65_535 ||
    !same(value.matchedPeer.txt, value.advertised.txt) ||
    value.transport !== value.advertised.txt.transport ||
    value.protocolVersion !== value.advertised.txt.protocol_version ||
    value.daemonVersion !== value.advertised.txt.daemon_version
  ) {
    fail("P-28 browsed peer does not match advertised identity and transport");
  }
  validateDiscovery(
    value.discovery,
    value.advertised.instance,
    "P-28 peer product discovery",
  );
  return value;
}

function validateHealthyStatus(value, label) {
  if (
    value?.adapter !== "smart_hub_bridge" ||
    value.status !== "bridge_control_ok" ||
    value.blocker !== "" ||
    !/\/health/u.test(value.health_probe ?? "") ||
    !/\/api\/display/u.test(value.control_probe ?? "") ||
    !(value.health_response ?? "") ||
    !(value.control_response ?? "")
  ) {
    fail(`${label} does not prove live SmartHub health and actionable control`);
  }
}

function validateDegradedStatus(value) {
  if (
    value?.adapter !== "smart_hub_bridge" ||
    value.status !== "blocked_bridge_not_reachable" ||
    !(value.blocker ?? "") ||
    (value.health_response ?? "") !== "" ||
    (value.control_response ?? "") !== ""
  ) {
    fail("P-28 outage retained stale healthy state or omitted its blocker");
  }
}

function validateCompositor(value, expected) {
  exactKeys(
    value,
    [
      "dbusSessionBus",
      "desktop",
      "display",
      "displayServer",
      "sessionId",
      "waylandDisplay",
    ],
    "P-28 compositor truth",
  );
  const expectedServer = expected.session.toLowerCase();
  if (
    !value.desktop.toLowerCase().includes(expected.desktop.toLowerCase()) ||
    value.displayServer !== expectedServer ||
    value.dbusSessionBus !== true ||
    (expectedServer === "x11" && !(value.display ?? "")) ||
    (expectedServer === "wayland" && !(value.waylandDisplay ?? ""))
  ) {
    fail("P-28 compositor/session evidence is dishonest");
  }
}

function validateAtspi(
  snapshot,
  state,
  marker,
  pid,
  peerInstance,
  startedAt,
  endedAt,
) {
  const value = parseJson(snapshot.bytes, `P-28 ${state} AT-SPI`);
  exactKeys(
    value,
    [
      "application",
      "capturedAt",
      "desktopPid",
      "focusedName",
      "marker",
      "nodes",
      "nonce",
      "producer",
      "route",
      "selectedOperation",
      "state",
      "statusText",
    ],
    `P-28 ${state} AT-SPI`,
  );
  const capturedAt = timestamp(
    value.capturedAt,
    `P-28 ${state} AT-SPI capture`,
  );
  const expectedOperation = state === "discovered" ? "discover" : "status";
  const expectedStatus =
    state === "discovered" ? peerInstance : EXPECTED_STATUS[state];
  if (
    value.producer !== "openburnbar-p28-atspi-live-v1" ||
    value.marker !== marker.marker ||
    value.nonce !== marker.nonce ||
    value.application !== "OpenBurnBar" ||
    value.desktopPid !== pid ||
    value.route !== "smarthub" ||
    value.state !== state ||
    value.selectedOperation !== expectedOperation ||
    capturedAt < startedAt ||
    capturedAt > endedAt ||
    !/Run operation/iu.test(value.focusedName ?? "") ||
    !(value.statusText ?? "")
      .toLowerCase()
      .includes(expectedStatus.toLowerCase()) ||
    !Array.isArray(value.nodes) ||
    value.nodes.length < 8
  ) {
    fail(`P-28 ${state} AT-SPI is stale, replayed, or not state-bound`);
  }
  const operation = value.nodes.find((node) =>
    /Operation/iu.test(node.name ?? ""),
  );
  const run = value.nodes.find((node) =>
    /Run operation/iu.test(node.name ?? ""),
  );
  if (
    !operation ||
    !run ||
    !Array.isArray(run.actions) ||
    run.actions.length === 0
  ) {
    fail(`P-28 ${state} AT-SPI controls are not actionable`);
  }
  return value;
}

function validateTranscript(value, marker, peer, expected, startedAt, endedAt) {
  exactKeys(
    value,
    [
      "accessibility",
      "compositor",
      "endedAt",
      "installed",
      "marker",
      "nonce",
      "operations",
      "peerManifest",
      "producer",
      "restoration",
      "runtime",
      "session",
      "startedAt",
    ],
    "P-28 native transcript",
  );
  const nativeStart = timestamp(value.startedAt, "P-28 native start");
  const nativeEnd = timestamp(value.endedAt, "P-28 native end");
  if (
    value.producer !== "openburnbar-p28-installed-smarthub-native-v1" ||
    value.marker !== marker.marker ||
    value.nonce !== marker.nonce ||
    nativeStart !== startedAt ||
    nativeEnd !== endedAt ||
    nativeEnd < nativeStart
  ) {
    fail("P-28 transcript is not bound to the live installed session");
  }
  validateInstalled(
    value.installed,
    expected,
    "P-28 transcript installed identity",
  );
  if (!same(value.installed, marker.installed))
    fail("P-28 marker and transcript installed identities diverge");
  exactKeys(
    value.runtime,
    ["capability", "manifest", "sha256"],
    "P-28 runtime proof",
  );
  if (
    value.runtime.sha256 !== marker.runtimeManifestSha256 ||
    value.runtime.sha256 !== digest(value.runtime.manifest) ||
    value.runtime.capability?.id !== "smarthub.control" ||
    value.runtime.capability?.state !== "available" ||
    !value.runtime.manifest.capabilities?.some(
      (item) => item.id === "smarthub.control" && item.state === "available",
    )
  ) {
    fail("P-28 runtime capability digest or live SmartHub state is forged");
  }
  exactKeys(
    value.peerManifest,
    ["endpoint", "instance", "sha256"],
    "P-28 transcript peer binding",
  );
  if (
    value.peerManifest.sha256 !== marker.peerManifestSha256 ||
    value.peerManifest.instance !== peer.advertised.instance ||
    value.peerManifest.endpoint !==
      `${peer.matchedPeer.hostName}:${peer.matchedPeer.port}`
  ) {
    fail("P-28 transcript peer provenance does not match the live manifest");
  }
  validateCompositor(value.compositor, expected);
  exactKeys(
    value.session,
    [
      "fixtureMode",
      "isolatedHome",
      "isolatedSupport",
      "primaryDesktopPid",
      "relaunchDesktopPid",
    ],
    "P-28 native session",
  );
  if (
    value.session.fixtureMode !== false ||
    value.session.isolatedHome !== true ||
    value.session.isolatedSupport !== true ||
    !Number.isSafeInteger(value.session.primaryDesktopPid) ||
    !Number.isSafeInteger(value.session.relaunchDesktopPid) ||
    value.session.primaryDesktopPid === value.session.relaunchDesktopPid
  ) {
    fail("P-28 desktop restart identity or containment is invalid");
  }
  exactKeys(
    value.operations,
    ["controlled", "degraded", "discovery", "recovered", "recovery"],
    "P-28 operations",
  );
  exactKeys(
    value.operations.discovery,
    ["peer", "result"],
    "P-28 discovery operation",
  );
  if (
    !same(value.operations.discovery.peer, peer.matchedPeer) ||
    !same(value.operations.discovery.result, peer.discovery)
  ) {
    fail("P-28 discovery operation was substituted after peer capture");
  }
  validateHealthyStatus(value.operations.controlled, "P-28 controlled state");
  validateDegradedStatus(value.operations.degraded);
  validateHealthyStatus(value.operations.recovered, "P-28 recovered state");
  exactKeys(
    value.operations.recovery,
    [
      "bridgeResumed",
      "controlRecovered",
      "daemonRestarted",
      "desktopRestarted",
      "healthRecovered",
      "peerIdentityPersisted",
      "staleHealthyResultBlocked",
    ],
    "P-28 recovery",
  );
  if (Object.values(value.operations.recovery).some((item) => item !== true)) {
    fail("P-28 recovery is partial or retains stale healthy state");
  }
  exactKeys(
    value.accessibility,
    [
      "actionableControls",
      "captures",
      "focusRestored",
      "liveStatusObserved",
      "route",
    ],
    "P-28 accessibility summary",
  );
  exactKeys(
    value.accessibility.captures,
    P28_STATES,
    "P-28 accessibility captures",
  );
  if (
    value.accessibility.route !== "smarthub" ||
    value.accessibility.actionableControls !== true ||
    value.accessibility.focusRestored !== true ||
    value.accessibility.liveStatusObserved !== true
  ) {
    fail("P-28 controls, focus, or live status are not accessible");
  }
  exactKeys(
    value.restoration,
    [
      "bridgePidsAfter",
      "bridgePidsBefore",
      "daemonActiveAfter",
      "daemonServiceStateRestored",
      "daemonWasActive",
      "desktopPidsAfter",
      "desktopPidsBefore",
      "exactBridgeProcessesRestored",
      "exactDesktopProcessesRestored",
    ],
    "P-28 restoration",
  );
  validatePidList(value.restoration.bridgePidsBefore, "P-28 bridge before");
  validatePidList(value.restoration.bridgePidsAfter, "P-28 bridge after");
  validatePidList(value.restoration.desktopPidsBefore, "P-28 desktop before", {
    empty: true,
  });
  validatePidList(value.restoration.desktopPidsAfter, "P-28 desktop after", {
    empty: true,
  });
  if (
    !same(
      value.restoration.bridgePidsBefore,
      value.restoration.bridgePidsAfter,
    ) ||
    !same(
      value.restoration.desktopPidsBefore,
      value.restoration.desktopPidsAfter,
    ) ||
    value.restoration.daemonWasActive !== true ||
    value.restoration.daemonActiveAfter !== true ||
    value.restoration.daemonServiceStateRestored !== true ||
    value.restoration.exactBridgeProcessesRestored !== true ||
    value.restoration.exactDesktopProcessesRestored !== true
  ) {
    fail("P-28 cleanup or exact process restoration failed");
  }
  return value;
}

export function validateP28InstalledSession(document, binding) {
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
    "P-28 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p28-installed-smarthub-session-v1"
  ) {
    fail("P-28 session identity is invalid");
  }
  const envelope = validateInstalledSessionEnvelope(
    document,
    binding,
    P28_REQUIREMENT_ID,
    "P-28 installed session",
  );
  validateInstalledInventory(document, binding);
  const marker = validateMarker(document.marker, envelope.expected);
  const evidenceKeys = [
    "marker",
    "nativeTranscript",
    "peerManifest",
    ...P28_STATES.flatMap((state) => [
      `${state}Screenshot`,
      `${state}Accessibility`,
    ]),
  ];
  exactKeys(document.evidence, evidenceKeys, "P-28 evidence");
  const markerSnapshot = artifact(
    binding.repoRoot,
    binding.environmentId,
    document.evidence.marker,
    "P-28 marker artifact",
    { mediaType: "json" },
  );
  if (!same(parseJson(markerSnapshot.bytes, "P-28 marker artifact"), marker))
    fail("P-28 embedded marker differs from its native runner artifact");
  const peerSnapshot = artifact(
    binding.repoRoot,
    binding.environmentId,
    document.evidence.peerManifest,
    "P-28 peer manifest",
    { mediaType: "json" },
  );
  if (peerSnapshot.sha256 !== marker.peerManifestSha256)
    fail("P-28 peer manifest digest changed after native capture");
  const peer = validatePeerManifest(
    parseJson(peerSnapshot.bytes, "P-28 peer manifest"),
    marker,
    envelope.startedAt,
    envelope.endedAt,
  );
  const nativeSnapshot = artifact(
    binding.repoRoot,
    binding.environmentId,
    document.evidence.nativeTranscript,
    "P-28 native transcript",
    { mediaType: "json" },
  );
  const transcript = validateTranscript(
    parseJson(nativeSnapshot.bytes, "P-28 native transcript"),
    marker,
    peer,
    envelope.expected,
    envelope.startedAt,
    envelope.endedAt,
  );
  const screenshotHashes = new Set();
  const accessibilityHashes = new Set();
  for (const state of P28_STATES) {
    const screenshot = artifact(
      binding.repoRoot,
      binding.environmentId,
      document.evidence[`${state}Screenshot`],
      `P-28 ${state} screenshot`,
      { mediaType: "png", minimumBytes: 256 },
    );
    const image = validatePng(screenshot.bytes, `P-28 ${state} screenshot`);
    if (
      image.nonBlankPixelRatio < 0.05 ||
      screenshotHashes.has(screenshot.sha256)
    ) {
      fail("P-28 screenshots are blank, duplicated, or replayed");
    }
    screenshotHashes.add(screenshot.sha256);
    const accessibility = artifact(
      binding.repoRoot,
      binding.environmentId,
      document.evidence[`${state}Accessibility`],
      `P-28 ${state} AT-SPI`,
      { mediaType: "json" },
    );
    if (accessibilityHashes.has(accessibility.sha256))
      fail("P-28 AT-SPI evidence is duplicated or replayed");
    accessibilityHashes.add(accessibility.sha256);
    const expectedPid =
      state === "recovered"
        ? transcript.session.relaunchDesktopPid
        : transcript.session.primaryDesktopPid;
    const atspi = validateAtspi(
      accessibility,
      state,
      marker,
      expectedPid,
      peer.advertised.instance,
      envelope.startedAt,
      envelope.endedAt,
    );
    const capture = transcript.accessibility.captures[state];
    exactKeys(
      capture,
      [
        "atspiSha256",
        "capturedAt",
        "focusedName",
        "screenshotSha256",
        "statusText",
      ],
      `P-28 ${state} transcript capture`,
    );
    if (
      capture.atspiSha256 !== accessibility.sha256 ||
      capture.screenshotSha256 !== screenshot.sha256 ||
      capture.capturedAt !== atspi.capturedAt ||
      capture.focusedName !== atspi.focusedName ||
      capture.statusText !== atspi.statusText
    ) {
      fail(`P-28 ${state} transcript capture digest or state was substituted`);
    }
  }
  const evidence = [
    ...Object.values(document.evidence),
    ...envelope.attestation,
  ];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-28 reuses or substitutes an evidence artifact");
  return { document, evidence, marker, peer, transcript };
}

export function buildP28Proof({ session, source, collectedAt }) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p28-smarthub-proof-v1",
    requirementId: P28_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source,
    claim: {
      installedCandidate: true,
      liveDaemonPeerDiscovery: true,
      liveHealthAndControl: true,
      honestCapabilityLoss: true,
      staleStateRejected: true,
      reconnectAndRestartPersistence: true,
      actionableAccessibleControls: true,
      compositorSessionBound: true,
      exactRestoration: true,
    },
  };
}

export function validateP28Proof({ snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-28 proof");
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
    "P-28 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p28-smarthub-proof-v1" ||
    proof.requirementId !== P28_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate?.runId !== String(binding.candidateRunId) ||
    proof.candidate?.artifactDigest !== binding.candidateArtifactDigest
  ) {
    fail("P-28 proof identity or candidate binding is invalid");
  }
  const source = artifact(
    binding.repoRoot,
    binding.environmentId,
    proof.source,
    "P-28 proof source",
    { mediaType: "json" },
  );
  const validated = validateP28InstalledSession(
    parseJson(source.bytes, "P-28 proof source"),
    binding,
  );
  validateCollectedAt(
    proof.collectedAt,
    Date.parse(validated.document.capture.endedAt),
  );
  const expected = buildP28Proof({
    session: validated.document,
    source: proof.source,
    collectedAt: proof.collectedAt,
  }).claim;
  if (digest(proof.claim) !== digest(expected))
    fail("P-28 proof claim is forged");
  return { proof, source: proof.source, ...validated };
}
